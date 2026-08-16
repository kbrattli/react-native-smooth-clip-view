#include "SmoothClipAndroid.h"
#include "SmoothClipAnimationId.h"
#include "SmoothClipAnimationCurve.h"
#include "SmoothClipTrace.h"
#include "SmoothClipVelocityTracker.h"

#include <fbjni/fbjni.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <limits>
#include <mutex>
#include <optional>
#include <unordered_map>
#include <vector>

#include <unistd.h>

namespace smoothclip {
namespace {

using facebook::jni::alias_ref;
using facebook::jni::global_ref;

enum class Ownership { Interactive, Native };
enum class AnimationKind { Timing, Spring, Keyframes };
enum class ViewParticipation { Deferred, Active, Suspended };

// Load-bearing invariant, not just a convenience clock: advance()'s frame-clock
// anchor compares this value ABSOLUTELY against a choreographer frame stamp
// (std::min), so the two must share an epoch. They do — bionic's steady_clock,
// System.nanoTime() behind Choreographer#frameTimeNanos, and the
// SystemClock.uptimeMillis() Reanimated stamps its own animations with are all
// CLOCK_MONOTONIC since boot. (The anchor this replaced subtracted two samples
// of this clock and was epoch-independent; the min() is not.)
//
// Breaking that invariant fails silently and asymmetrically. A frame axis
// running BEHIND the wall axis degrades quietly: min() always adopts the frame
// stamp and animations lose only their sub-frame start offset. A frame axis
// running AHEAD is fatal: min() always keeps startedAtS, the first fraction
// (frame - startedAtS)/duration clamps to 1, and every animation completes on
// its first frame.
double nowSeconds() {
  return std::chrono::duration<double>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

struct ActiveAnimation {
  int32_t id = 0;
  AnimationKind kind = AnimationKind::Timing;
  Presentation start{{0, 0, 0, 0, 0}, 0, 0};
  Presentation target{{0, 0, 0, 0, 0}, 0, 0};
  Presentation current{{0, 0, 0, 0, 0}, 0, 0};
  TimingAnimation timing{};
  SpringAnimation spring{};
  // Owns the keyframes and their precomputed monotone-cubic tangents; the
  // tangent solve happens on reset(), never per frame.
  KeyframeCurve keyframes;
  double durationS = 0;
  double startedAtS = 0;
  // Integrated spring state (channels: x, y, width, height, radius, tx, ty).
  std::array<double, 7> springPosition{};
  std::array<double, 7> springVelocity{};
  double lastFrameS = 0;
  bool finished = true;
  // False while the animation is latched, and held out of animatingDrivers()
  // so it cannot tick. Two ways in: built before any host view could display
  // (pre-registration, or a detached/unsized host), or re-latched by
  // unregisterViewAndroid when the last DISPLAYABLE host left mid-flight.
  // Started by whichever lifecycle/geometry update first sees a displayable
  // entry; each rebases the clock through startLatchedAnimation.
  bool started = false;
  // False until the first advance() translates the wall-clock start stamp
  // onto the choreographer frame-time axis (elapsed-preserving). Every
  // startedAtS stamp clears it so a re-latched resume re-anchors too — except
  // a start that carried the JS-captured Reanimated stamp, which arrives
  // pre-anchored (see startAnimation) and must not be min()'d again.
  bool frameClockAnchored = false;
};

// Per-view fanout state. Density and host metrics are pushed from Kotlin at
// register time and on size/density changes; density 0 (not pushed yet) falls
// back to DIP delivery through setClipPresentationDip.
struct ViewEntry {
  global_ref<JSmoothClipView> view;
  double density = 0;
  double hostWidthPx = 0;
  double hostHeightPx = 0;
  bool lifecycleVisible = false;
  ViewParticipation participation = ViewParticipation::Deferred;
};

struct DriverState {
  Presentation latest{{0, 0, 0, 0, 0}, 0, 0};
  bool hasLatest = false;
  Ownership ownership = Ownership::Interactive;
  std::vector<ViewEntry> views;
  std::optional<ActiveAnimation> animation;
  // Set by destroyDriver while views are still registered (StrictMode effect
  // replay, hosts mounted in another subtree). The entry is erased when the
  // last view leaves and revived by a take-ownership setPresentation.
  bool destroyed = false;

  // 'inherit' velocity samples; recording/coalescing/projection live in the
  // shared cpp/SmoothClipVelocityTracker.h (behavior-paired with iOS).
  VelocitySampleHistory samples;
};

struct CompletionSink {
  const void *owner = nullptr;
  CompletionCallback callback;
};

std::unordered_map<uint64_t, DriverState> &registry() {
  static std::unordered_map<uint64_t, DriverState> value;
  return value;
}

CompletionSink &completionSink() {
  static CompletionSink sink;
  return sink;
}

// The sink is written from the JS thread (installBindings / invalidate) and
// invoked on main. Invoking under the lock also keeps the owning bindings
// state alive for the duration of the callback.
std::mutex &completionSinkMutex() {
  static std::mutex value;
  return value;
}

Presentation unavailablePresentation() {
  // Non-finite geometry makes the JS side fall back to its current value
  // instead of applying zeros.
  const double nan = std::numeric_limits<double>::quiet_NaN();
  return {{nan, nan, nan, nan, nan}, nan, nan};
}

// --- Main-thread confinement ----------------------------------------------

// fbjni handle used once to identify the Android main thread; later checks
// compare thread ids.
struct JLooper : facebook::jni::JavaClass<JLooper> {
  static constexpr auto kJavaDescriptor = "Landroid/os/Looper;";
};

std::atomic<pid_t> gMainThreadId{0};

// The registry, the frame loop, and every view mutation are main-thread only:
// Choreographer.getInstance() is per-thread, and binding the loop to the JS
// thread would race Fabric mounting and mutate views off-main. The worklets
// UI runtime executes on the main thread, so supported usage always passes;
// direct off-main calls fail defined instead of racing.
bool isOnMainThread() {
  const pid_t tid = gettid();
  const pid_t cached = gMainThreadId.load(std::memory_order_relaxed);
  if (cached != 0) return tid == cached;
  const auto looperClass = JLooper::javaClassStatic();
  static const auto getMainLooper =
      looperClass->getStaticMethod<JLooper()>("getMainLooper");
  static const auto myLooper =
      looperClass->getStaticMethod<JLooper()>("myLooper");
  const auto main = getMainLooper(looperClass);
  const auto mine = myLooper(looperClass);
  const bool isMain = mine &&
      facebook::jni::Environment::current()->IsSameObject(
          main.get(), mine.get());
  if (isMain) gMainThreadId.store(tid, std::memory_order_relaxed);
  return isMain;
}

// --- Frame loop -----------------------------------------------------------

// fbjni handle for the Kotlin frame-loop bridge. The loop posts through the
// Java Choreographer (CALLBACK_ANIMATION) rather than the NDK AChoreographer:
// the NDK instance is a separate frame source on the main Looper whose
// ordering against the Java Choreographer's traversal (draw) phase is
// undefined, so advances landing after the traversal presented one vsync
// late — a randomly flipping ±1-frame phase between the clip and Reanimated
// content. Posting into the same doFrame pass as Reanimated makes every
// advance precede the draw by construction. It also retires the 32-bit
// truncated-timestamp fallback: Java frameTimeNanos is a jlong everywhere.
//
// doCallbacks() extracts by wall-now rather than by frame time, so a post
// issued from an earlier phase of a frame already in flight (CALLBACK_INPUT —
// a gesture end that starts an animation) runs in that same doFrame instead
// of the next one. Harmless (the fraction is ~0 and the write dedupes in
// Kotlin) and one frame cheaper at the handoff than the NDK path allowed.
struct JSmoothClipBindings : facebook::jni::JavaClass<JSmoothClipBindings> {
  static constexpr auto kJavaDescriptor =
      "Lcom/smoothclipview/SmoothClipBindings;";
};

bool gFrameScheduled = false;
void onFrameImpl(double now);

void scheduleFrame() {
  if (gFrameScheduled) return;
  // Defensive: never bind the per-thread choreographer to a non-main thread.
  if (!isOnMainThread()) return;
  static const auto scheduleMethod =
      JSmoothClipBindings::javaClassStatic()->getStaticMethod<void()>(
          "scheduleFrame");
  scheduleMethod(JSmoothClipBindings::javaClassStatic());
  // Set only after a successful post: if the up-call ever threw with the flag
  // already true, the loop would be dead until process restart.
  gFrameScheduled = true;
}

// --- Math (ported from SmoothClipRegistry.kt so both platforms match) -----
//
// clamp01, toChannels/fromChannels, interpolate, the frame-clock anchor and the
// keyframe curve now live in cpp/SmoothClipAnimationCurve.h so a test binary can
// reach them without linking fbjni; ios/tests pins their behavior.

// Springs settle below these per-channel thresholds (DIP and DIP/s).
constexpr double kSpringSettleDisplacement = 0.05;
constexpr double kSpringSettleVelocity = 1.0;
// Settle-based termination is backed by a hard cap so a pathological
// configuration cannot run the frame loop forever.
constexpr double kSpringMaxDurationS = 10.0;

// Semi-implicit Euler per channel, substepped: one frame-sized step is only
// stable for omega*dt < 2, and accepted stiffness/mass ratios exceed that at
// the 64 ms clamp. Fixed <= 1/240 s substeps stay stable beyond
// stiffness/mass = 200k. Termination is settle-based: every channel must be
// near its target and nearly stationary at the same time.
bool advanceSpring(ActiveAnimation &animation, double now) {
  const auto target = toChannels(animation.target);
  double dt = now - animation.lastFrameS;
  animation.lastFrameS = now;
  if (dt < 0) dt = 0;
  if (dt > 0.064) dt = 0.064;
  const double mass = animation.spring.mass;
  const double stiffness = animation.spring.stiffness;
  const double damping = animation.spring.damping;
  constexpr double kMaxStepS = 1.0 / 240.0;
  while (dt > 0) {
    const double step = std::min(dt, kMaxStepS);
    dt -= step;
    for (int index = 0; index < 7; index += 1) {
      const double displacement =
          animation.springPosition[index] - target[index];
      const double acceleration =
          (-stiffness * displacement -
           damping * animation.springVelocity[index]) /
          mass;
      animation.springVelocity[index] += acceleration * step;
      animation.springPosition[index] += animation.springVelocity[index] * step;
    }
  }
  bool settled = true;
  for (int index = 0; index < 7; index += 1) {
    if (!std::isfinite(animation.springPosition[index]) ||
        !std::isfinite(animation.springVelocity[index])) {
      // A divergent configuration must never freeze the clip: end at target.
      animation.springPosition = target;
      animation.springVelocity = {};
      animation.current = animation.target;
      return true;
    }
    if (std::abs(animation.springPosition[index] - target[index]) >
            kSpringSettleDisplacement ||
        std::abs(animation.springVelocity[index]) > kSpringSettleVelocity) {
      settled = false;
    }
  }
  animation.current = fromChannels(animation.springPosition);
  return settled || now - animation.startedAtS >= kSpringMaxDurationS;
}

bool systemAnimatorsEnabled() {
  static const auto valueAnimatorClass =
      facebook::jni::findClassStatic("android/animation/ValueAnimator");
  static const auto method =
      valueAnimatorClass->getStaticMethod<jboolean()>("areAnimatorsEnabled");
  return method(valueAnimatorClass) != 0;
}

bool shouldReduceMotion(int32_t setting) {
  if (setting == 1) return true;
  if (setting == 2) return false;
  return !systemAnimatorsEnabled();
}

// --- State helpers --------------------------------------------------------

void emitCompletion(uint64_t driverId, int32_t animationId, bool finished) {
  std::lock_guard<std::mutex> lock(completionSinkMutex());
  if (completionSink().callback) {
    completionSink().callback(driverId, animationId, finished);
  }
}

// Terminal per-frame delivery: scale DIP -> px and normalize against the
// pushed host metrics in C++, so the JNI call carries final pixel floats and
// the Kotlin side reduces to field stores + invalidateOutline().
void deliverToView(const ViewEntry &entry, const Presentation &presentation) {
  if (entry.density <= 0) {
    entry.view->applyClip(presentation);
    return;
  }
  const double density = entry.density;
  NormalizedClip clip;
  if (!SmoothClipNormalize(
          presentation.clip.x * density,
          presentation.clip.y * density,
          presentation.clip.width * density,
          presentation.clip.height * density,
          presentation.clip.radius * density,
          entry.hostWidthPx,
          entry.hostHeightPx,
          clip)) {
    return;
  }
  const double translateX = presentation.contentTranslateX * density;
  const double translateY = presentation.contentTranslateY * density;
  // Atomic reject, mirroring the Kotlin DIP path's all-or-nothing gate.
  if (!std::isfinite(translateX) || !std::isfinite(translateY)) return;
  entry.view->applyClipPx(clip, translateX, translateY);
}

void applyToViews(DriverState &state, const Presentation &presentation) {
  for (const auto &entry : state.views) {
    deliverToView(entry, presentation);
  }
}

void applyPresentation(DriverState &state, const Presentation &presentation) {
  state.latest = presentation;
  state.hasLatest = true;
  state.ownership = Ownership::Interactive;
  applyToViews(state, presentation);
}

std::vector<uint64_t> &animatingDrivers() {
  static std::vector<uint64_t> value;
  return value;
}

// Every state.animation.reset() routes through here so the choreographer only
// visits animating drivers. Removal is eager: a stale id surviving a driver
// erase/recreate cycle would let one frame integrate the animation twice.
void clearActiveAnimation(uint64_t driverId, DriverState &state) {
  state.animation.reset();
  for (ViewEntry &entry : state.views) {
    entry.participation = ViewParticipation::Deferred;
  }
  auto &active = animatingDrivers();
  active.erase(
      std::remove(active.begin(), active.end(), driverId), active.end());
}

void finishActive(uint64_t driverId, DriverState &state, bool finished) {
  if (!state.animation.has_value()) return;
  const int32_t animationId = state.animation->id;
  clearActiveAnimation(driverId, state);
  emitCompletion(driverId, animationId, finished);
}

Presentation prepareAnimation(
    uint64_t driverId,
    DriverState &state,
    AnimationStart start,
    Presentation target) {
  const Presentation visibleBefore =
      state.animation.has_value() ? state.animation->current : state.latest;
  const bool acceptsInteractiveStart =
      start.hasInteractiveStart && state.ownership == Ownership::Interactive;
  finishActive(driverId, state, false);
  const Presentation resolvedStart =
      acceptsInteractiveStart ? start.interactiveStart : visibleBefore;
  if (acceptsInteractiveStart) {
    state.latest = resolvedStart;
    applyToViews(state, resolvedStart);
  }
  state.latest = target;
  state.hasLatest = true;
  state.ownership = Ownership::Native;
  return resolvedStart;
}

// A view can only render the animation once it is attached to a window and
// has pushed real host geometry; a clock started before that burns progress
// no one can see (the transparentModal mount pattern).
bool entryDisplayable(const ViewEntry &entry) {
  return entry.hostWidthPx > 0 && entry.hostHeightPx > 0 &&
      entry.lifecycleVisible;
}

bool anyDisplayableView(const DriverState &state) {
  for (const ViewEntry &entry : state.views) {
    if (entryDisplayable(entry)) return true;
  }
  return false;
}

// Starts a latched animation: rebases the clock so no progress was burned
// while no view could display, then joins the choreographer loop.
void startLatchedAnimation(uint64_t driverId, DriverState &state) {
  auto &animation = *state.animation;
  animation.started = true;
  animation.startedAtS = nowSeconds();
  animation.lastFrameS = animation.startedAtS;
  // Load-bearing for re-latch resumes: unregisterViewAndroid rewrites this
  // ActiveAnimation in place, so a stale anchor would replay the fraction-0
  // first frame the anchor exists to remove.
  animation.frameClockAnchored = false;
  auto &active = animatingDrivers();
  if (std::find(active.begin(), active.end(), driverId) == active.end()) {
    active.push_back(driverId);
  }
  for (ViewEntry &entry : state.views) {
    if (entryDisplayable(entry)) {
      entry.participation = ViewParticipation::Active;
    }
  }
  applyToViews(state, animation.start);
  scheduleFrame();
}

int32_t startAnimation(
    uint64_t driverId,
    DriverState &state,
    ActiveAnimation animation,
    double startedAtHintS) {
  // With a JS-captured hint the start stamp is Reanimated's own
  // (`__frameTimestamp || _getAnimationTimestamp()`, read in the worklet that
  // issued this call), already on the axis min() only approximates — so the
  // animation arrives pre-anchored and advance() must not min() it against
  // the dispatching frame, which for a CALLBACK_INPUT start is EARLIER than
  // the call and would re-open the intra-frame lead the hint closes. Without
  // a hint (NaN: latch-less legacy callers, tests, iOS ignoring the field)
  // this reduces exactly to the old nowSeconds() + min() anchor path.
  const double wallNow = nowSeconds();
  const StartStamp stamp = resolveStartStamp(startedAtHintS, wallNow);
  animation.startedAtS = stamp.startedAtS;
  animation.lastFrameS = stamp.startedAtS;
  animation.frameClockAnchored = stamp.frameClockAnchored;
  // current = start even while latched is load-bearing: cancelAnimation,
  // beginInteraction, prepareAnimation's visibleBefore and registerView's
  // visible all read animation->current, giving a never-rendered latch
  // freeze-at-start / replace-from-start semantics with no extra branches.
  animation.current = animation.start;
  animation.started = anyDisplayableView(state);
  state.animation = std::move(animation);
  for (ViewEntry &entry : state.views) {
    entry.participation = state.animation->started && entryDisplayable(entry)
        ? ViewParticipation::Active
        : ViewParticipation::Deferred;
  }
  if (!state.animation->started) {
    // Latch: no host view can display yet (animateTo raced the mount, or
    // every host is detached/unsized). The first displayable registration,
    // host-geometry push, or window attach rebases the clock, joins
    // animatingDrivers() and schedules the frame loop. Non-zero id is still
    // returned so the JS side does not treat this as rejection.
    return state.animation->id;
  }
  auto &active = animatingDrivers();
  if (std::find(active.begin(), active.end(), driverId) == active.end()) {
    active.push_back(driverId);
  }
  applyToViews(state, state.animation->start);
  scheduleFrame();
  return state.animation->id;
}

void relatchIfNoDisplayable(uint64_t driverId, DriverState &state) {
  if (!state.animation.has_value() || !state.animation->started ||
      anyDisplayableView(state)) {
    return;
  }
  auto &animation = *state.animation;
  for (ViewEntry &entry : state.views) {
    if (entry.participation == ViewParticipation::Active) {
      entry.participation = ViewParticipation::Suspended;
    }
  }

  if (animation.kind == AnimationKind::Timing) {
    const TimingContinuation continuation = timingContinuationAtFrame(
        animation.timing,
        animation.start,
        animation.target,
        animation.lastFrameS,
        animation.startedAtS,
        animation.durationS);
    animation.current = continuation.start;
    animation.timing = continuation.animation;
    animation.durationS = continuation.animation.durationMs / 1000.0;
  } else if (animation.kind == AnimationKind::Keyframes) {
    const KeyframeContinuation continuation = keyframeContinuationAtFrame(
        animation.keyframes.frames(),
        animation.current,
        animation.target,
        animation.lastFrameS,
        animation.startedAtS,
        animation.durationS);
    animation.current = continuation.start;
    animation.keyframes.reset(continuation.frames);
    animation.durationS = continuation.durationMs / 1000.0;
  }

  if (state.destroyed ||
      (animation.kind != AnimationKind::Spring && animation.durationS <= 0)) {
    state.ownership = Ownership::Interactive;
    finishActive(driverId, state, false);
    return;
  }

  animation.start = animation.current;
  animation.started = false;
  animation.frameClockAnchored = false;
  auto &active = animatingDrivers();
  active.erase(
      std::remove(active.begin(), active.end(), driverId), active.end());
}

void reconcileViewDisplayability(
    uint64_t driverId,
    DriverState &state,
    ViewEntry &entry) {
  if (!state.animation.has_value()) return;
  if (!state.animation->started) {
    if (entryDisplayable(entry)) startLatchedAnimation(driverId, state);
    return;
  }

  if (entryDisplayable(entry)) {
    if (entry.participation != ViewParticipation::Active) {
      entry.participation = ViewParticipation::Active;
      deliverToView(entry, state.animation->current);
    }
  } else if (entry.participation == ViewParticipation::Active) {
    entry.participation = ViewParticipation::Suspended;
  }
  relatchIfNoDisplayable(driverId, state);
}

void advance(uint64_t driverId, DriverState &state, double now) {
  ActiveAnimation &animation = *state.animation;

  if (!animation.frameClockAnchored) {
    // This is the stamp-less/latch fallback. Worklet-issued animations carry
    // Reanimated's exact `__frameTimestamp || _getAnimationTimestamp()` value
    // and arrive pre-anchored, so they skip this approximation — including the
    // CALLBACK_INPUT case where the current frame stamp predates the call.
    // Here startedAtS/lastFrameS hold nowSeconds() sampled at native latch
    // attach or by an older caller, while `now` is the frame's vsync stamp on
    // the same CLOCK_MONOTONIC timebase. Taking the earlier stamp prevents a
    // mid-frame native start from duplicating fraction zero.
    //
    // Deliberately NOT a wall-elapsed rebase (`now - (nowSeconds() -
    // startedAtS)`): that bakes THIS frame's dispatch latency into the curve
    // for the animation's whole duration, de-phasing the clip from parallel
    // Reanimated content by however much main-thread work happened to run
    // before us on frame one — worst on the first frame of a heavy
    // transition, which is exactly when it is sampled. Catching up after a
    // stall needs no help here either: Choreographer#doFrame snaps a late
    // frameTimeNanos forward to within one frame interval of now (jitter
    // correction), for every CALLBACK_ANIMATION client at once, so the clip
    // and the content stall and catch up together.
    animation.startedAtS = anchorStartTime(animation.startedAtS, now);
    animation.lastFrameS = animation.startedAtS;
    animation.frameClockAnchored = true;
  }

  bool done = false;
  if (animation.kind == AnimationKind::Spring) {
    done = advanceSpring(animation, now);
  } else {
    // This is the frame whose presentation is delivered below. Lifecycle
    // re-latch must trim from this timestamp, never from a later wall sample.
    animation.lastFrameS = now;
    const double fraction =
        timingFraction(now, animation.startedAtS, animation.durationS);
    if (animation.kind == AnimationKind::Keyframes) {
      animation.current = animation.keyframes.evaluate(fraction);
    } else {
      const double eased = cubicBezier(
          animation.timing.controlPoint1X,
          animation.timing.controlPoint1Y,
          animation.timing.controlPoint2X,
          animation.timing.controlPoint2Y,
          fraction);
      animation.current = interpolate(animation.start, animation.target, eased);
    }
    done = fraction >= 1.0;
  }
  // The completion branch below fans out the exact target; applying the
  // integrated value too would double every JNI crossing on the final frame.
  if (!done) applyToViews(state, animation.current);

  if (done) {
    const int32_t animationId = animation.id;
    bool finished = animation.finished;
    for (const ViewEntry &entry : state.views) {
      if (entry.participation == ViewParticipation::Suspended) {
        finished = false;
        break;
      }
    }
    const Presentation target = animation.target;
    clearActiveAnimation(driverId, state);
    state.latest = target;
    state.hasLatest = true;
    state.ownership = Ownership::Interactive;
    applyToViews(state, target);
    emitCompletion(driverId, animationId, finished);
  }
}

void onFrameImpl(double now) {
  SMOOTH_CLIP_TRACE("SmoothClip.frame");
  gFrameScheduled = false;
  // Snapshot: advance() clears live-list entries on completion. advance()
  // never erases registry entries and never starts animations (completion
  // delivery hops through CallInvoker::invokeAsync), so the find() guard
  // below covers every way a copied id can go stale within this frame. The
  // scratch vector is main-thread confined and reused so the steady-state
  // frame loop stays allocation-free.
  static std::vector<uint64_t> scratch;
  scratch = animatingDrivers();
  for (const uint64_t driverId : scratch) {
    auto iterator = registry().find(driverId);
    if (iterator == registry().end() ||
        !iterator->second.animation.has_value()) {
      continue;
    }
    advance(driverId, iterator->second, now);
  }
  if (!animatingDrivers().empty()) scheduleFrame();
}

} // namespace

// Advances the frame loop; reached from SmoothClipBindings.nativeOnFrame
// inside Choreographer#doFrame. Nothing may unwind back into doFrame — fbjni
// would rethrow it as a Java exception and take down the main thread. Clear
// any pending JNI exception, keep the loop scheduled, and let the next frame
// re-scan.
void onFrameAndroid(double frameTimeS) {
  try {
    onFrameImpl(frameTimeS);
  } catch (...) {
    JNIEnv *env = facebook::jni::Environment::current();
    if (env != nullptr && env->ExceptionCheck()) env->ExceptionClear();
    try {
      scheduleFrame();
    } catch (...) {
      // gFrameScheduled stays false; the next animation start re-schedules.
    }
  }
}

// --- Public smoothclip:: interface (shared with iOS via SmoothClipRegistry.h)

void setCompletionCallback(const void *owner, CompletionCallback callback) {
  std::lock_guard<std::mutex> lock(completionSinkMutex());
  completionSink().owner = owner;
  completionSink().callback = std::move(callback);
}

void clearCompletionCallback(const void *owner) {
  std::lock_guard<std::mutex> lock(completionSinkMutex());
  if (completionSink().owner != owner) return;
  completionSink().owner = nullptr;
  completionSink().callback = nullptr;
}

void setPresentation(
    uint64_t driverId,
    Presentation presentation,
    bool takeOwnership,
    bool overridePendingAnimation,
    bool recordVelocity) {
  if (!isOnMainThread()) return;
  // After the thread guard: the macro's function-local SectionStats is
  // main-thread confined, so an off-main call must not touch it.
  SMOOTH_CLIP_TRACE("SmoothClip.setPresentation");
  auto iterator = registry().find(driverId);
  if (!takeOwnership) {
    if (iterator == registry().end() || iterator->second.destroyed) {
      // A stale interactive delivery must not resurrect a destroyed driver.
      return;
    }
  } else if (iterator == registry().end()) {
    // Same create-or-revive semantics operator[] had; a single hash lookup.
    iterator = registry().try_emplace(driverId).first;
  }
  auto &state = iterator->second;
  if (!takeOwnership && state.ownership != Ownership::Interactive) return;
  if (takeOwnership) {
    state.destroyed = false;
    // Passive seeds and public setters must not displace newer pending intent.
    // The fused animation.from write is different: it is the caller's newest,
    // authoritative start and explicitly opts in to cancelling the old latch.
    if (state.animation.has_value() && !state.animation->started &&
        !overridePendingAnimation) {
      return;
    }
    finishActive(driverId, state, false);
  }
  state.latest = presentation;
  state.hasLatest = true;
  state.ownership = Ownership::Interactive;
  if (recordVelocity) {
    recordVelocitySample(state.samples, toChannels(presentation), nowSeconds());
  } else if (state.samples.hasLatest) {
    // An unrecorded hot write still moved the geometry, so any recorded pair
    // no longer describes the finger: without this, a pre-drag pair inside
    // the staleness window would launch a later 'inherit' spring with motion
    // the drag never produced. No clock read, and the hasLatest guard (false
    // implies the history is already default) makes the steady-state cost of
    // an untracked drag stream one load and a predictable branch per frame.
    clearVelocitySamples(state.samples);
  }
  applyToViews(state, presentation);
}

Presentation beginInteraction(uint64_t driverId) {
  if (!isOnMainThread()) return unavailablePresentation();
  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return unavailablePresentation();
  auto &state = iterator->second;
  state.destroyed = false;
  if (!state.animation.has_value()) {
    state.ownership = Ownership::Interactive;
    return state.latest;
  }
  const int32_t animationId = state.animation->id;
  const Presentation current = state.animation->current;
  clearActiveAnimation(driverId, state);
  state.latest = current;
  state.hasLatest = true;
  state.ownership = Ownership::Interactive;
  // The frozen frame came from native animation movement, not an interactive
  // write. Do not let it become a later `initialVelocity: inherit` sample.
  applyToViews(state, current);
  emitCompletion(driverId, animationId, false);
  return current;
}

int32_t animateTiming(
    uint64_t driverId,
    AnimationStart start,
    Presentation presentation,
    TimingAnimation animation) {
  if (!isOnMainThread()) return 0;
  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) {
    if (!start.hasInteractiveStart) return 0;
    iterator = registry().try_emplace(driverId).first;
    iterator->second.latest = start.interactiveStart;
    iterator->second.hasLatest = true;
  }
  auto &state = iterator->second;
  state.destroyed = false;
  const int32_t animationId = allocateAnimationId();
  const Presentation resolvedStart =
      prepareAnimation(driverId, state, start, presentation);
  if (shouldReduceMotion(animation.reduceMotion) || animation.durationMs <= 0) {
    applyPresentation(state, presentation);
    emitCompletion(driverId, animationId, true);
    return animationId;
  }
  ActiveAnimation active;
  active.id = animationId;
  active.kind = AnimationKind::Timing;
  active.timing = animation;
  active.start = resolvedStart;
  active.target = presentation;
  active.durationS = animation.durationMs / 1000.0;
  return startAnimation(driverId, state, std::move(active), start.startedAtHintS);
}

int32_t animateSpring(
    uint64_t driverId,
    AnimationStart start,
    Presentation presentation,
    SpringAnimation animation) {
  if (!isOnMainThread()) return 0;
  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) {
    if (!start.hasInteractiveStart) return 0;
    iterator = registry().try_emplace(driverId).first;
    iterator->second.latest = start.interactiveStart;
    iterator->second.hasLatest = true;
  }
  auto &state = iterator->second;
  state.destroyed = false;
  const int32_t animationId = allocateAnimationId();
  // Scalar velocity along the current-to-target trajectory; each channel is
  // seeded with velocity·displacement to match the iOS CASpringAnimation
  // per-keypath behavior.
  const double velocity = animation.inheritVelocity
      ? inheritedVelocity(state.samples, toChannels(presentation), nowSeconds())
      : animation.initialVelocity;
  const Presentation resolvedStart =
      prepareAnimation(driverId, state, start, presentation);
  if (shouldReduceMotion(animation.reduceMotion)) {
    applyPresentation(state, presentation);
    emitCompletion(driverId, animationId, true);
    return animationId;
  }
  ActiveAnimation active;
  active.id = animationId;
  active.kind = AnimationKind::Spring;
  active.spring = animation;
  active.spring.initialVelocity = velocity;
  active.spring.inheritVelocity = false;
  active.start = resolvedStart;
  active.target = presentation;
  active.durationS = kSpringMaxDurationS;
  const auto startChannels = toChannels(resolvedStart);
  const auto targetChannels = toChannels(presentation);
  for (int index = 0; index < 7; index += 1) {
    active.springPosition[index] = startChannels[index];
    active.springVelocity[index] =
        velocity * (targetChannels[index] - startChannels[index]);
  }
  return startAnimation(driverId, state, std::move(active), start.startedAtHintS);
}

int32_t animateKeyframes(
    uint64_t driverId,
    AnimationStart start,
    Presentation presentation,
    double durationMs,
    std::vector<Keyframe> keyframes,
    int32_t reduceMotion) {
  if (!isOnMainThread()) return 0;
  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) {
    if (!start.hasInteractiveStart) return 0;
    iterator = registry().try_emplace(driverId).first;
    iterator->second.latest = start.interactiveStart;
    iterator->second.hasLatest = true;
  }
  auto &state = iterator->second;
  state.destroyed = false;
  const int32_t animationId = allocateAnimationId();
  const Presentation resolvedStart =
      prepareAnimation(driverId, state, start, presentation);
  if (shouldReduceMotion(reduceMotion) || durationMs <= 0 ||
      keyframes.size() < 2) {
    applyPresentation(state, presentation);
    emitCompletion(driverId, animationId, true);
    return animationId;
  }
  ActiveAnimation active;
  active.id = animationId;
  active.kind = AnimationKind::Keyframes;
  active.keyframes.reset(std::move(keyframes));
  active.start = resolvedStart;
  active.target = presentation;
  active.durationS = durationMs / 1000.0;
  return startAnimation(driverId, state, std::move(active), start.startedAtHintS);
}

int32_t rejectAnimation(uint64_t driverId) {
  if (!isOnMainThread()) return 0;
  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return 0;
  const int32_t animationId = allocateAnimationId();
  emitCompletion(driverId, animationId, false);
  return animationId;
}

CancelResult cancelAnimation(
    uint64_t driverId,
    int32_t animationId,
    bool useTarget) {
  if (!isOnMainThread()) return {false, unavailablePresentation()};
  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) {
    return {false, {{0, 0, 0, 0, 0}, 0, 0}};
  }
  auto &state = iterator->second;
  if (!state.animation.has_value() ||
      (animationId > 0 && animationId != state.animation->id)) {
    return {false, state.animation.has_value() ? state.animation->current
                                               : state.latest};
  }
  const Presentation result =
      useTarget ? state.animation->target : state.animation->current;
  const int32_t activeId = state.animation->id;
  clearActiveAnimation(driverId, state);
  state.latest = result;
  state.hasLatest = true;
  state.ownership = Ownership::Interactive;
  applyToViews(state, result);
  emitCompletion(driverId, activeId, false);
  return {true, result};
}

void destroyDriver(uint64_t driverId) {
  if (!isOnMainThread()) return;
  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return;
  auto &state = iterator->second;
  state.ownership = Ownership::Interactive;
  finishActive(driverId, state, false);
  // A destroyed driver's interaction history must not seed a revived
  // incarnation: the revival seed would otherwise pair with these samples and
  // refresh the staleness clock with motion no finger produced. (iOS clears
  // its per-view histories at the same point.)
  state.samples = VelocitySampleHistory{};
  if (state.views.empty()) {
    registry().erase(iterator);
  } else {
    // Views can outlive the hook briefly (StrictMode effect replay, hosts in
    // another subtree). Keep a tombstone so their registration stays intact;
    // it is erased when the last view leaves and revived by the hook's
    // authoritative take-ownership re-seed.
    state.destroyed = true;
  }
}

// --- Android view lifecycle ----------------------------------------------

void JSmoothClipView::applyClip(const Presentation &presentation) const {
  static const auto method =
      javaClassStatic()
          ->getMethod<void(
              jdouble, jdouble, jdouble, jdouble, jdouble, jdouble, jdouble)>(
              "setClipPresentationDip");
  method(
      self(),
      presentation.clip.x,
      presentation.clip.y,
      presentation.clip.width,
      presentation.clip.height,
      presentation.clip.radius,
      presentation.contentTranslateX,
      presentation.contentTranslateY);
}

void JSmoothClipView::applyClipPx(
    const NormalizedClip &clip,
    double contentTranslateXPx,
    double contentTranslateYPx) const {
  static const auto method =
      javaClassStatic()
          ->getMethod<void(
              jfloat, jfloat, jfloat, jfloat, jfloat, jfloat, jfloat)>(
              "setClipPresentationPx");
  method(
      self(),
      static_cast<jfloat>(clip.left),
      static_cast<jfloat>(clip.top),
      static_cast<jfloat>(clip.right),
      static_cast<jfloat>(clip.bottom),
      static_cast<jfloat>(clip.radius),
      static_cast<jfloat>(contentTranslateXPx),
      static_cast<jfloat>(contentTranslateYPx));
}

void registerViewAndroid(
    uint64_t driverId,
    alias_ref<JSmoothClipView> view,
    Presentation initialPresentation,
    double density,
    double hostWidthPx,
    double hostHeightPx,
    bool lifecycleVisible) {
  auto &state = registry()[driverId];
  state.destroyed = false;
  if (!state.hasLatest) {
    state.latest = initialPresentation;
    state.hasLatest = true;
  }
  const Presentation visible = state.animation.has_value()
      ? state.animation->current
      : state.latest;
  JNIEnv *env = facebook::jni::Environment::current();
  for (auto &existing : state.views) {
    if (env->IsSameObject(existing.view.get(), view.get())) {
      existing.density = density;
      existing.hostWidthPx = hostWidthPx;
      existing.hostHeightPx = hostHeightPx;
      existing.lifecycleVisible = lifecycleVisible;
      deliverToView(existing, visible);
      reconcileViewDisplayability(driverId, state, existing);
      return;
    }
  }
  ViewEntry entry{
      facebook::jni::make_global(view),
      density,
      hostWidthPx,
      hostHeightPx,
      lifecycleVisible,
      ViewParticipation::Deferred};
  // `visible` above already delivered animation->current (= start) to the
  // registering view — the correct first frame for a latched animation.
  deliverToView(entry, visible);
  state.views.push_back(std::move(entry));
  reconcileViewDisplayability(driverId, state, state.views.back());
}

void setViewHostGeometryAndroid(
    uint64_t driverId,
    alias_ref<JSmoothClipView> view,
    double density,
    double hostWidthPx,
    double hostHeightPx) {
  if (!isOnMainThread()) return;
  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return;
  auto &state = iterator->second;
  JNIEnv *env = facebook::jni::Environment::current();
  for (auto &entry : state.views) {
    if (!env->IsSameObject(entry.view.get(), view.get())) continue;
    entry.density = density;
    entry.hostWidthPx = hostWidthPx;
    entry.hostHeightPx = hostHeightPx;
    if (state.hasLatest) {
      deliverToView(
          entry,
          state.animation.has_value() ? state.animation->current
                                      : state.latest);
    }
    reconcileViewDisplayability(driverId, state, entry);
    return;
  }
}

void setViewLifecycleVisibilityAndroid(
    uint64_t driverId,
    alias_ref<JSmoothClipView> view,
    bool lifecycleVisible) {
  if (!isOnMainThread()) return;
  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return;
  auto &state = iterator->second;
  JNIEnv *env = facebook::jni::Environment::current();
  for (auto &entry : state.views) {
    if (!env->IsSameObject(entry.view.get(), view.get())) continue;
    entry.lifecycleVisible = lifecycleVisible;
    reconcileViewDisplayability(driverId, state, entry);
    return;
  }
}

void unregisterViewAndroid(
    uint64_t driverId,
    alias_ref<JSmoothClipView> view) {
  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return;
  auto &state = iterator->second;
  bool removed = false;
  bool removedParticipant = false;
  JNIEnv *env = facebook::jni::Environment::current();
  for (auto view_it = state.views.begin(); view_it != state.views.end();) {
    if (env->IsSameObject(view_it->view.get(), view.get())) {
      removedParticipant = removedParticipant ||
          view_it->participation != ViewParticipation::Deferred;
      view_it = state.views.erase(view_it);
      removed = true;
    } else {
      ++view_it;
    }
  }
  if (removed && state.animation.has_value()) {
    // Only a host that actually joined (or is unresolved after suspension)
    // affects completion. A detached/unsized registration that stayed deferred
    // never installed or rendered this animation.
    if (removedParticipant) state.animation->finished = false;
    if (!isOnMainThread()) {
      // Blast-radius reduction, NOT a synchronization fix — be clear about
      // which. Both call sites (SmoothClipViewManager.onAfterUpdateTransaction
      // and onDropViewInstance) are Fabric mount operations, so this branch is
      // unreachable in supported usage; the erase above and participant-based
      // `finished` write are still unsynchronized if that ever stops holding. The erase
      // cannot be skipped — dropping it would leak this view's global_ref for
      // the process lifetime — but everything below can be, and should be: it
      // mutates animatingDrivers(), the vector the choreographer callback walks
      // on the main thread. Record the unfinished flag and leave the animation
      // for the next main-thread event (attach, host geometry, destroy) to
      // resolve.
    } else {
      relatchIfNoDisplayable(driverId, state);
    }
  }
  if (state.destroyed && state.views.empty()) {
    registry().erase(iterator);
  }
}

} // namespace smoothclip
