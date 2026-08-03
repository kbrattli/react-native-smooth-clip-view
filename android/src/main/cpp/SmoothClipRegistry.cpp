#include "SmoothClipAndroid.h"
#include "SmoothClipAnimationCurve.h"
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
  // Wall-clock twin of startedAtS: stamped together with it, NEVER moved by
  // the frame-clock anchor. The unregister re-latch remainder needs honest
  // wall elapsed and reads this; the animation curve itself paces on the
  // anchored startedAtS frame axis.
  double wallStartedAtS = 0;
  // Integrated spring state (channels: x, y, width, height, radius, tx, ty).
  std::array<double, 7> springPosition{};
  std::array<double, 7> springVelocity{};
  double lastFrameS = 0;
  bool finished = true;
  // False while the animation is latched: built before any host view
  // registered, held un-rendered (and out of animatingDrivers()) until the
  // first registerViewAndroid rebases the clock and starts it.
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
};

struct DriverState {
  Presentation latest{{0, 0, 0, 0, 0}, 0, 0};
  bool hasLatest = false;
  Ownership ownership = Ownership::Interactive;
  std::vector<ViewEntry> views;
  std::optional<ActiveAnimation> animation;
  int32_t nextAnimationId = 0;
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

double cubicBezier(
    double x1,
    double y1,
    double x2,
    double y2,
    double input) {
  double low = 0;
  double high = 1;
  for (int iteration = 0; iteration < 14; iteration += 1) {
    const double t = (low + high) / 2;
    const double inverse = 1 - t;
    const double x = 3 * inverse * inverse * t * x1 +
        3 * inverse * t * t * x2 + t * t * t;
    if (x < input) {
      low = t;
    } else {
      high = t;
    }
  }
  const double t = (low + high) / 2;
  const double inverse = 1 - t;
  return 3 * inverse * inverse * t * y1 + 3 * inverse * t * t * y2 +
      t * t * t;
}

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

int32_t allocateAnimationId(DriverState &state) {
  state.nextAnimationId =
      state.nextAnimationId == std::numeric_limits<int32_t>::max()
      ? 1
      : state.nextAnimationId + 1;
  return state.nextAnimationId;
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
      entry.view->isViewAttachedToWindow();
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
  animation.wallStartedAtS = animation.startedAtS;
  // Load-bearing for re-latch resumes: unregisterViewAndroid rewrites this
  // ActiveAnimation in place, so a stale anchor would replay the fraction-0
  // first frame the anchor exists to remove.
  animation.frameClockAnchored = false;
  auto &active = animatingDrivers();
  if (std::find(active.begin(), active.end(), driverId) == active.end()) {
    active.push_back(driverId);
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
  // Wall axis for the re-latch remainder keeps the native call stamp: the
  // hint is at most a frame older and the remainder math wants honest wall
  // elapsed from when the animation actually began integrating.
  animation.wallStartedAtS = wallNow;
  animation.frameClockAnchored = stamp.frameClockAnchored;
  // current = start even while latched is load-bearing: cancelAnimation,
  // beginInteraction, prepareAnimation's visibleBefore and registerView's
  // visible all read animation->current, giving a never-rendered latch
  // freeze-at-start / replace-from-start semantics with no extra branches.
  animation.current = animation.start;
  animation.started = anyDisplayableView(state);
  state.animation = std::move(animation);
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

void advance(uint64_t driverId, DriverState &state, double now) {
  ActiveAnimation &animation = *state.animation;

  if (!animation.frameClockAnchored) {
    // startedAtS/lastFrameS hold nowSeconds() sampled mid-frame at the
    // animateTo call / latch attach, but `now` is the frame's vsync
    // timestamp — the same CLOCK_MONOTONIC timebase at an earlier sampling
    // point. Reanimated stamps a parallel withTiming with
    // `global.__frameTimestamp || wallNow` and then paces it on frame stamps,
    // so min() reproduces both of its branches exactly and the two curves
    // stay phase-identical: a call issued between frames keeps its wall stamp
    // (the frame that dispatches us is later, so the first fraction is
    // already positive — no duplicated start frame), and a call issued inside
    // the very frame that dispatches us adopts that frame's stamp instead of
    // clamping to 0.
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
    // wallStartedAtS deliberately keeps the wall axis (re-latch remainder).
  }

  bool done = false;
  if (animation.kind == AnimationKind::Spring) {
    done = advanceSpring(animation, now);
  } else {
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
    const bool finished = animation.finished;
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
    bool takeOwnership) {
  if (!isOnMainThread()) return;
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
    // A held latch is strictly newer intent than this write: the latch was
    // created after whatever value the caller read (the hook's seed replays
    // a SharedValue that an earlier animateTo already advanced to its
    // target). Cancelling it here would seed the target and turn the pending
    // animation into a static jump. Callers that want to override a latch
    // cancel it explicitly first.
    if (state.animation.has_value() && !state.animation->started) {
      return;
    }
    finishActive(driverId, state, false);
  }
  state.latest = presentation;
  state.hasLatest = true;
  state.ownership = Ownership::Interactive;
  recordVelocitySample(state.samples, toChannels(presentation), nowSeconds());
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
  // Plain record, not a reset — iOS parity (smoothClipFreezePresentation
  // records the frozen value). Pairing the frozen mid-flight presentation
  // with the last real sample lets a grab-and-instant-refling inherit
  // bounded recent motion instead of launching dead; an unchanged value
  // dedupes to a no-op and ages out through the staleness guard.
  recordVelocitySample(state.samples, toChannels(current), nowSeconds());
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
  if (iterator == registry().end()) return 0;
  auto &state = iterator->second;
  state.destroyed = false;
  const int32_t animationId = allocateAnimationId(state);
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
  if (iterator == registry().end()) return 0;
  auto &state = iterator->second;
  state.destroyed = false;
  const int32_t animationId = allocateAnimationId(state);
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
  if (iterator == registry().end()) return 0;
  auto &state = iterator->second;
  state.destroyed = false;
  const int32_t animationId = allocateAnimationId(state);
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
  const int32_t animationId = allocateAnimationId(iterator->second);
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

bool JSmoothClipView::isViewAttachedToWindow() const {
  static const auto method =
      javaClassStatic()->getMethod<jboolean()>("isAttachedToWindow");
  return method(self());
}

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
    double hostHeightPx) {
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
      deliverToView(existing, visible);
      if (state.animation.has_value() && !state.animation->started &&
          entryDisplayable(existing)) {
        startLatchedAnimation(driverId, state);
      }
      return;
    }
  }
  ViewEntry entry{
      facebook::jni::make_global(view), density, hostWidthPx, hostHeightPx};
  // `visible` above already delivered animation->current (= start) to the
  // registering view — the correct first frame for a latched animation.
  deliverToView(entry, visible);
  state.views.push_back(std::move(entry));
  if (state.animation.has_value() && !state.animation->started &&
      entryDisplayable(state.views.back())) {
    // Start the latched animation: rebase the clock so the first frame
    // integrates from now, not from the pre-mount animateTo call. Gated on
    // displayability — a mount-time registration from a detached subtree
    // holds the latch until window attach / first host geometry.
    // Note this function has no isOnMainThread() guard (Kotlin calls it from
    // the view's main-thread attach path); scheduleFrame() is itself
    // main-thread-gated, so an off-main register cannot bind the
    // choreographer to the wrong thread.
    startLatchedAnimation(driverId, state);
  }
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
    if (state.animation.has_value() && !state.animation->started &&
        entryDisplayable(entry)) {
      // First real host geometry made this view displayable.
      startLatchedAnimation(driverId, state);
    }
    return;
  }
}

void viewBecameDisplayableAndroid(
    uint64_t driverId,
    alias_ref<JSmoothClipView> view) {
  if (!isOnMainThread()) return;
  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return;
  auto &state = iterator->second;
  if (!state.animation.has_value() || state.animation->started) return;
  JNIEnv *env = facebook::jni::Environment::current();
  for (auto &entry : state.views) {
    if (!env->IsSameObject(entry.view.get(), view.get())) continue;
    if (entryDisplayable(entry)) {
      startLatchedAnimation(driverId, state);
    }
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
  JNIEnv *env = facebook::jni::Environment::current();
  for (auto view_it = state.views.begin(); view_it != state.views.end();) {
    if (env->IsSameObject(view_it->view.get(), view.get())) {
      view_it = state.views.erase(view_it);
      removed = true;
    } else {
      ++view_it;
    }
  }
  if (removed && state.animation.has_value()) {
    state.animation->finished = false;
    if (state.views.empty() && !state.animation->started) {
      // A held latch returns to its original zero-view state; the next
      // displayable registration still starts it (or destroyDriver cancels
      // it). Completing it here would betray the pending intent.
    } else if (state.views.empty()) {
      auto &animation = *state.animation;
      // wallStartedAtS, not startedAtS: post-anchor the latter lives on the
      // shifted frame axis and would overstate elapsed by the first
      // callback's dispatch latency, shortening the resumed remainder and
      // advancing the keyframe rebase past the rendered position.
      const double elapsedS = nowSeconds() - animation.wallStartedAtS;
      const double remainingS = std::max(0.0, animation.durationS - elapsedS);
      const bool canResume = !state.destroyed &&
          (animation.kind == AnimationKind::Spring || remainingS > 0);
      if (!canResume) {
        // The animation ends here; release ownership so a later remount's
        // interactive updates are not dropped.
        state.ownership = Ownership::Interactive;
        finishActive(driverId, state, false);
      } else {
        // The last rendering host left mid-flight (remount, screen swap).
        // Completing here would leave `latest` at the target and statically
        // snap any re-registering host straight to it. Re-latch instead:
        // freeze the remaining animation at its current geometry so the
        // next displayable host resumes it with the true remaining time.
        // destroyDriver cancels a latch that never finds a host, so the
        // completion cannot hang.
        if (animation.kind == AnimationKind::Timing) {
          animation.durationS = remainingS;
        } else if (animation.kind == AnimationKind::Keyframes) {
          const double progress = animation.durationS <= 0
              ? 1.0
              : clamp01(elapsedS / animation.durationS);
          std::vector<Keyframe> remaining;
          remaining.push_back({0, animation.current});
          for (const Keyframe &frame : animation.keyframes.frames()) {
            if (frame.offset <= progress) continue;
            remaining.push_back(
                {(frame.offset - progress) / (1 - progress),
                 frame.presentation});
          }
          if (remaining.size() == 1) {
            remaining.push_back({1, animation.target});
          }
          // reset() re-solves the tangents for the pruned curve and rewinds
          // the segment cursor; the resumed run must not inherit either.
          animation.keyframes.reset(std::move(remaining));
          animation.durationS = remainingS;
        }
        animation.start = animation.current;
        animation.started = false;
        // A held latch must not tick: leave animatingDrivers() without
        // resetting the animation (the eager-removal rule the choreographer
        // loop depends on).
        auto &active = animatingDrivers();
        active.erase(
            std::remove(active.begin(), active.end(), driverId),
            active.end());
      }
    }
  }
  if (state.destroyed && state.views.empty()) {
    registry().erase(iterator);
  }
}

} // namespace smoothclip
