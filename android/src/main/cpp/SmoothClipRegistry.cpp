#include "SmoothClipAndroid.h"

#include <android/choreographer.h>
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
  std::vector<Keyframe> keyframes;
  double durationS = 0;
  double startedAtS = 0;
  // Integrated spring state (channels: x, y, width, height, radius, tx, ty).
  std::array<double, 7> springPosition{};
  std::array<double, 7> springVelocity{};
  double lastFrameS = 0;
  bool finished = true;
  // False while the animation is latched: built before any host view
  // registered, held un-rendered (and out of animatingDrivers()) until the
  // first registerViewAndroid rebases the clock and starts it.
  bool started = false;
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

  bool hasPreviousSample = false;
  bool hasLatestSample = false;
  Presentation previousSample{{0, 0, 0, 0, 0}, 0, 0};
  Presentation latestSample{{0, 0, 0, 0, 0}, 0, 0};
  double previousSampleTimeS = 0;
  double latestSampleTimeS = 0;
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
// AChoreographer_getInstance is per-thread, and binding the loop to the JS
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

bool gFrameScheduled = false;
void onFrameImpl(double now);
void onFrameLegacy(long frameTimeNanos, void *data);

void scheduleFrame() {
  if (gFrameScheduled) return;
  // Defensive: never bind the per-thread choreographer to a non-main thread.
  if (!isOnMainThread()) return;
  AChoreographer *choreographer = AChoreographer_getInstance();
  if (choreographer == nullptr) return;
  gFrameScheduled = true;
  // AChoreographer_postFrameCallback64 (API 29+) only matters on 32-bit ABIs,
  // where `long` truncates the timestamp; onFrameLegacy falls back to the
  // clock there, so the legacy entry point covers every case.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  AChoreographer_postFrameCallback(choreographer, &onFrameLegacy, nullptr);
#pragma clang diagnostic pop
}

// --- Math (ported from SmoothClipRegistry.kt so both platforms match) -----

double clamp01(double value) { return std::min(1.0, std::max(0.0, value)); }

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

// Presentation <-> per-channel array (x, y, width, height, radius, tx, ty).
std::array<double, 7> toChannels(const Presentation &presentation) {
  return {presentation.clip.x,
          presentation.clip.y,
          presentation.clip.width,
          presentation.clip.height,
          presentation.clip.radius,
          presentation.contentTranslateX,
          presentation.contentTranslateY};
}

Presentation fromChannels(const std::array<double, 7> &channels) {
  return Presentation{
      {channels[0], channels[1], channels[2], channels[3], channels[4]},
      channels[5],
      channels[6]};
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

Presentation interpolate(
    const Presentation &from,
    const Presentation &to,
    double progress) {
  const auto mix = [progress](double start, double end) {
    return start + (end - start) * progress;
  };
  return Presentation{
      {mix(from.clip.x, to.clip.x),
       mix(from.clip.y, to.clip.y),
       mix(from.clip.width, to.clip.width),
       mix(from.clip.height, to.clip.height),
       mix(from.clip.radius, to.clip.radius)},
      mix(from.contentTranslateX, to.contentTranslateX),
      mix(from.contentTranslateY, to.contentTranslateY)};
}

Presentation interpolateKeyframes(
    const std::vector<Keyframe> &frames,
    double progress) {
  size_t upper = 1;
  while (upper < frames.size() - 1 && progress > frames[upper].offset) {
    upper += 1;
  }
  const Keyframe &lower = frames[upper - 1];
  const Keyframe &higher = frames[upper];
  const double span = higher.offset - lower.offset;
  const double local = span <= 0 ? 1.0 : (progress - lower.offset) / span;
  return interpolate(lower.presentation, higher.presentation, clamp01(local));
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

void recordInteractiveSample(DriverState &state, const Presentation &presentation) {
  state.hasPreviousSample = state.hasLatestSample;
  state.previousSample = state.latestSample;
  state.previousSampleTimeS = state.latestSampleTimeS;
  state.hasLatestSample = true;
  state.latestSample = presentation;
  state.latestSampleTimeS = nowSeconds();
}

double inheritedVelocity(DriverState &state, const Presentation &target) {
  if (!state.hasPreviousSample || !state.hasLatestSample) return 0;
  const double elapsed = state.latestSampleTimeS - state.previousSampleTimeS;
  if (elapsed <= 0 || nowSeconds() - state.latestSampleTimeS > 0.1) return 0;
  const double sample[7] = {
      state.latestSample.clip.x - state.previousSample.clip.x,
      state.latestSample.clip.y - state.previousSample.clip.y,
      state.latestSample.clip.width - state.previousSample.clip.width,
      state.latestSample.clip.height - state.previousSample.clip.height,
      state.latestSample.clip.radius - state.previousSample.clip.radius,
      state.latestSample.contentTranslateX - state.previousSample.contentTranslateX,
      state.latestSample.contentTranslateY - state.previousSample.contentTranslateY};
  const double destination[7] = {
      target.clip.x - state.latestSample.clip.x,
      target.clip.y - state.latestSample.clip.y,
      target.clip.width - state.latestSample.clip.width,
      target.clip.height - state.latestSample.clip.height,
      target.clip.radius - state.latestSample.clip.radius,
      target.contentTranslateX - state.latestSample.contentTranslateX,
      target.contentTranslateY - state.latestSample.contentTranslateY};
  double numerator = 0;
  double denominator = 0;
  for (int index = 0; index < 7; index += 1) {
    numerator += sample[index] * destination[index];
    denominator += destination[index] * destination[index];
  }
  if (denominator <= 1e-12) return 0;
  const double result = numerator / elapsed / denominator;
  return std::isfinite(result) ? result : 0;
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

int32_t startAnimation(
    uint64_t driverId,
    DriverState &state,
    ActiveAnimation animation) {
  animation.startedAtS = nowSeconds();
  animation.lastFrameS = animation.startedAtS;
  // current = start even while latched is load-bearing: cancelAnimation,
  // beginInteraction, prepareAnimation's visibleBefore and registerView's
  // visible all read animation->current, giving a never-rendered latch
  // freeze-at-start / replace-from-start semantics with no extra branches.
  animation.current = animation.start;
  animation.started = !state.views.empty();
  state.animation = std::move(animation);
  if (!state.animation->started) {
    // Latch: no host view yet (animateTo raced the mount). The first
    // registerViewAndroid rebases the clock, joins animatingDrivers() and
    // schedules the frame loop. Non-zero id is still returned so the JS
    // side does not treat this as rejection.
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

  bool done = false;
  if (animation.kind == AnimationKind::Spring) {
    done = advanceSpring(animation, now);
  } else {
    const double fraction =
        animation.durationS <= 0
        ? 1.0
        : clamp01((now - animation.startedAtS) / animation.durationS);
    if (animation.kind == AnimationKind::Keyframes) {
      animation.current = interpolateKeyframes(animation.keyframes, fraction);
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

void onFrameLegacy(long frameTimeNanos, void * /*data*/) {
  // An fbjni exception must not unwind out of a C callback (std::terminate).
  // Clear it, keep the loop scheduled, and let the next frame re-scan.
  try {
#if defined(__LP64__) || (defined(__SIZEOF_POINTER__) && __SIZEOF_POINTER__ == 8)
    onFrameImpl(static_cast<double>(frameTimeNanos) / 1e9);
#else
    // 32-bit `long` truncates the nanosecond timestamp; fall back to the
    // clock.
    onFrameImpl(nowSeconds());
#endif
  } catch (...) {
    JNIEnv *env = facebook::jni::Environment::current();
    if (env != nullptr && env->ExceptionCheck()) env->ExceptionClear();
    scheduleFrame();
  }
}

} // namespace

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
    finishActive(driverId, state, false);
  }
  state.latest = presentation;
  state.hasLatest = true;
  state.ownership = Ownership::Interactive;
  recordInteractiveSample(state, presentation);
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
  state.hasPreviousSample = false;
  state.hasLatestSample = true;
  state.latestSample = current;
  state.latestSampleTimeS = nowSeconds();
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
  return startAnimation(driverId, state, std::move(active));
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
      ? inheritedVelocity(state, presentation)
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
  return startAnimation(driverId, state, std::move(active));
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
  active.keyframes = std::move(keyframes);
  active.start = resolvedStart;
  active.target = presentation;
  active.durationS = durationMs / 1000.0;
  return startAnimation(driverId, state, std::move(active));
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
  // The existing-view branch below is unreachable while an animation is
  // latched (a latch implies views was empty at animate time), so only the
  // new-view path needs to start latches.
  for (auto &existing : state.views) {
    if (env->IsSameObject(existing.view.get(), view.get())) {
      existing.density = density;
      existing.hostWidthPx = hostWidthPx;
      existing.hostHeightPx = hostHeightPx;
      deliverToView(existing, visible);
      return;
    }
  }
  ViewEntry entry{
      facebook::jni::make_global(view), density, hostWidthPx, hostHeightPx};
  // `visible` above already delivered animation->current (= start) to the
  // registering view — the correct first frame for a latched animation.
  deliverToView(entry, visible);
  state.views.push_back(std::move(entry));
  if (state.animation.has_value() && !state.animation->started) {
    // Start the latched animation: rebase the clock so the first frame
    // integrates from now, not from the pre-mount animateTo call.
    // Note this function has no isOnMainThread() guard (Kotlin calls it from
    // the view's main-thread attach path); scheduleFrame() is itself
    // main-thread-gated, so an off-main register cannot bind the
    // choreographer to the wrong thread.
    auto &animation = *state.animation;
    animation.started = true;
    animation.startedAtS = nowSeconds();
    animation.lastFrameS = animation.startedAtS;
    auto &active = animatingDrivers();
    if (std::find(active.begin(), active.end(), driverId) == active.end()) {
      active.push_back(driverId);
    }
    scheduleFrame();
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
    if (state.views.empty()) {
      // The animation ends here; release ownership so a later remount's
      // interactive updates are not dropped.
      state.ownership = Ownership::Interactive;
      finishActive(driverId, state, false);
    }
  }
  if (state.destroyed && state.views.empty()) {
    registry().erase(iterator);
  }
}

} // namespace smoothclip
