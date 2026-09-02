#include "SmoothClipAndroid.h"
#include "SmoothClipAnimationId.h"
#include "SmoothClipAnimationCurve.h"
#include "SmoothClipTrace.h"
#include "SmoothClipVelocityTracker.h"

#include <fbjni/fbjni.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
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
enum class AnimationKind { Timing, Spring };
enum class ViewParticipation { Deferred, Active };

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
  int32_t completionTag = 0;
  AnimationKind kind = AnimationKind::Timing;
  Presentation start{{0, 0, 0, 0, 0}, 0, 0};
  Presentation target{{0, 0, 0, 0, 0}, 0, 0};
  Presentation current{{0, 0, 0, 0, 0}, 0, 0};
  TimingAnimation timing{};
  SpringAnimation spring{};
  double durationS = 0;
  double startedAtS = 0;
  // Integrated spring state. Shadow channels are skipped when neither endpoint
  // has a visible shadow.
  Channels springPosition{};
  Channels springVelocity{};
  std::size_t springChannelCount = kBaseChannelCount;
  double lastFrameS = 0;
  ScalarSpringState scalarSpring{0, 0};
  // False only while a pre-ready animation waits for its first displayable
  // host. Once started, host loss freezes the visible presentation.
  bool started = false;
  // False until the first advance() translates the wall-clock start stamp
  // onto the choreographer frame-time axis (elapsed-preserving). Every
  // A start that carried the JS-captured Reanimated stamp arrives
  // pre-anchored (see startAnimation) and must not be min()'d again.
  bool frameClockAnchored = false;
};

// Per-view fanout state. Density and host metrics are pushed from Kotlin at
// register time and on size/density changes; density 0 falls back to DIP
// delivery until physical host metrics arrive.
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
  // Non-zero while this driver is an immutable member of one active group.
  int32_t groupId = 0;

  // 'inherit' velocity samples; recording/coalescing/projection live in the
  // shared cpp/SmoothClipVelocityTracker.h (behavior-paired with iOS).
  VelocitySampleHistory samples;
};

struct CompletionSink {
  const void *owner = nullptr;
  CompletionCallback callback;
};

struct GroupCompletionSink {
  const void *owner = nullptr;
  GroupCompletionCallback callback;
};

struct GroupMemberAnimation {
  uint64_t driverId = 0;
  ActiveAnimation animation;
};

struct ActiveGroup {
  uint64_t controllerId = 0;
  int32_t id = 0;
  int32_t completionTag = 0;
  AnimationKind kind = AnimationKind::Timing;
  TimingAnimation timing{};
  SpringAnimation spring{};
  ScalarSpringState scalarSpring{0, 0};
  double durationS = 0;
  double startedAtS = 0;
  double lastFrameS = 0;
  bool started = false;
  bool frameClockAnchored = false;
  std::vector<GroupMemberAnimation> members;
};

bool anyDisplayableView(const DriverState &state);

std::unordered_map<uint64_t, DriverState> &registry() {
  static std::unordered_map<uint64_t, DriverState> value;
  return value;
}

CompletionSink &completionSink() {
  static CompletionSink sink;
  return sink;
}

GroupCompletionSink &groupCompletionSink() {
  static GroupCompletionSink sink;
  return sink;
}

std::unordered_map<int32_t, ActiveGroup> &groupRegistry() {
  static std::unordered_map<int32_t, ActiveGroup> value;
  return value;
}

std::vector<int32_t> &animatingGroups() {
  static std::vector<int32_t> value;
  return value;
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
// clamp01, toChannels/fromChannels, interpolate, and the frame-clock anchor
// live in cpp/SmoothClipAnimationCurve.h so a test binary can reach them
// without linking fbjni; ios/tests pins their behavior.

std::array<double, 11> velocityChannels(const Presentation &presentation) {
  const Channels channels = toChannels(presentation);
  std::array<double, 11> result{};
  std::copy_n(channels.begin(), result.size(), result.begin());
  return result;
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
  const auto normalizedEndpoints = normalizeShadowEndpoints(
      animation.start, animation.target);
  const auto target = toChannels(normalizedEndpoints.second);
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
    for (std::size_t index = 0; index < animation.springChannelCount; index += 1) {
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
  for (std::size_t index = 0; index < animation.springChannelCount; index += 1) {
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
  animation.current = fromChannels(
      animation.springPosition,
      animation.start.clip.curve,
      animation.start.shadow.enabled || animation.target.shadow.enabled);
  if (!canonicalizePresentation(animation.current)) {
    animation.current = animation.target;
    return true;
  }
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

void emitCompletion(
    uint64_t driverId,
    int32_t animationId,
    int32_t completionTag,
    bool finished) {
  std::lock_guard<std::mutex> lock(completionSinkMutex());
  if (completionSink().callback) {
    completionSink().callback(
        driverId, animationId, completionTag, finished);
  }
}

void emitGroupCompletion(const ActiveGroup &group, bool finished) {
  std::vector<DriverSnapshot> snapshots;
  snapshots.reserve(group.members.size());
  for (const GroupMemberAnimation &member : group.members) {
    const auto iterator = registry().find(member.driverId);
    if (iterator == registry().end() || iterator->second.destroyed) {
      snapshots.push_back(
          {member.driverId, unavailablePresentation(), false});
    } else {
      snapshots.push_back({
          member.driverId,
          iterator->second.latest,
          anyDisplayableView(iterator->second),
      });
    }
  }
  std::lock_guard<std::mutex> lock(completionSinkMutex());
  if (groupCompletionSink().callback) {
    groupCompletionSink().callback(
        group.controllerId,
        group.id,
        group.completionTag,
        finished,
        std::move(snapshots));
  }
}

const GroupMemberAnimation *findGroupMember(
    int32_t groupId,
    uint64_t driverId) {
  const auto groupIterator = groupRegistry().find(groupId);
  if (groupIterator == groupRegistry().end()) return nullptr;
  for (const GroupMemberAnimation &member : groupIterator->second.members) {
    if (member.driverId == driverId) return &member;
  }
  return nullptr;
}

Presentation visiblePresentation(
    uint64_t driverId,
    const DriverState &state) {
  if (state.groupId != 0) {
    const GroupMemberAnimation *member =
        findGroupMember(state.groupId, driverId);
    if (member != nullptr) return member->animation.current;
  }
  return state.animation.has_value() ? state.animation->current : state.latest;
}

// Terminal per-frame delivery: scale canonical DIP geometry to pixels without
// consulting host metrics. Each SmoothClipView applies the fixed viewport crop.
void deliverToView(const ViewEntry &entry, const Presentation &presentation) {
  if (entry.density <= 0) {
    entry.view->applyClip(presentation);
    return;
  }
  const double density = entry.density;
  CanonicalClip clip;
  if (!SmoothClipCanonicalize(
          presentation.clip.x * density,
          presentation.clip.y * density,
          presentation.clip.width * density,
          presentation.clip.height * density,
          presentation.clip.radius * density,
          presentation.clip.topLeftRadius * density,
          presentation.clip.topRightRadius * density,
          presentation.clip.bottomRightRadius * density,
          presentation.clip.bottomLeftRadius * density,
          presentation.clip.curve,
          clip)) {
    return;
  }
  const double translateX = presentation.contentTranslateX * density;
  const double translateY = presentation.contentTranslateY * density;
  // Atomic reject, mirroring the Kotlin DIP path's all-or-nothing gate.
  if (!std::isfinite(translateX) || !std::isfinite(translateY) ||
      !std::isfinite(presentation.contentScale) ||
      presentation.contentScale <= 0) {
    return;
  }
  Shadow shadowPx = presentation.shadow;
  shadowPx.offsetX *= density;
  shadowPx.offsetY *= density;
  shadowPx.blurRadius *= density;
  shadowPx.spreadDistance *= density;
  entry.view->applyClipPx(
      clip,
      translateX,
      translateY,
      presentation.contentScale,
      shadowPx);
}

void applyToViews(DriverState &state, const Presentation &presentation) {
  for (const auto &entry : state.views) {
    deliverToView(entry, presentation);
  }
}

void setAutonomousMotion(DriverState &state, bool active) {
  for (const ViewEntry &entry : state.views) {
    entry.view->setAutonomousMotion(active);
  }
}

void applyAnimationFrameToViews(
    DriverState &state,
    const Presentation &presentation) {
  for (const auto &entry : state.views) {
    if (entry.participation == ViewParticipation::Active) {
      deliverToView(entry, presentation);
    }
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
  setAutonomousMotion(state, false);
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
  const int32_t completionTag = state.animation->completionTag;
  clearActiveAnimation(driverId, state);
  emitCompletion(driverId, animationId, completionTag, finished);
}

Presentation prepareAnimation(
    uint64_t driverId,
    DriverState &state,
    AnimationStart start,
    Presentation target) {
  const Presentation visibleBefore =
      state.animation.has_value() ? state.animation->current : state.latest;
  // `from` is an explicit part of the replacement transaction and therefore
  // overrides the sampled native frame even when the previous owner was a
  // native animation/group.
  const bool acceptsInteractiveStart = start.hasInteractiveStart;
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

bool allGroupMembersReady(const ActiveGroup &group) {
  for (const GroupMemberAnimation &member : group.members) {
    const auto iterator = registry().find(member.driverId);
    if (iterator == registry().end() || iterator->second.destroyed ||
        !anyDisplayableView(iterator->second)) {
      return false;
    }
  }
  return true;
}

void removeAnimatingGroup(int32_t groupId) {
  auto &active = animatingGroups();
  active.erase(std::remove(active.begin(), active.end(), groupId), active.end());
}

void applyGroupCurrent(const ActiveGroup &group) {
  // Group readiness is the participation contract. Each controller owns one
  // host, and host loss removes the group before another frame can advance.
  for (const GroupMemberAnimation &member : group.members) {
    const auto iterator = registry().find(member.driverId);
    if (iterator != registry().end()) {
      applyToViews(iterator->second, member.animation.current);
    }
  }
}

void startGroupFrameLoop(ActiveGroup &group) {
  assert(group.started);
  assert(allGroupMembersReady(group));
  for (const GroupMemberAnimation &member : group.members) {
    auto iterator = registry().find(member.driverId);
    if (iterator != registry().end()) {
      setAutonomousMotion(iterator->second, true);
    }
  }
  auto &active = animatingGroups();
  if (std::find(active.begin(), active.end(), group.id) == active.end()) {
    active.push_back(group.id);
  }
  applyGroupCurrent(group);
  scheduleFrame();
}

std::vector<DriverSnapshot> finishGroupImpl(
    int32_t groupId,
    bool useTarget,
    bool finished) {
  auto groupIterator = groupRegistry().find(groupId);
  if (groupIterator == groupRegistry().end()) return {};
  ActiveGroup group = std::move(groupIterator->second);
  groupRegistry().erase(groupIterator);
  removeAnimatingGroup(groupId);

  std::vector<DriverSnapshot> snapshots;
  snapshots.reserve(group.members.size());
  for (GroupMemberAnimation &member : group.members) {
    auto stateIterator = registry().find(member.driverId);
    if (stateIterator == registry().end()) {
      snapshots.push_back({member.driverId, unavailablePresentation(), false});
      continue;
    }
    DriverState &state = stateIterator->second;
    const Presentation result =
        useTarget ? member.animation.target : member.animation.current;
    state.groupId = 0;
    state.latest = result;
    state.hasLatest = true;
    state.ownership = Ownership::Interactive;
    setAutonomousMotion(state, false);
    applyToViews(state, result);
    snapshots.push_back(
        {member.driverId, result, !state.destroyed && anyDisplayableView(state)});
  }
  emitGroupCompletion(group, finished);
  return snapshots;
}

void startPendingGroup(ActiveGroup &group) {
  const double now = nowSeconds();
  group.started = true;
  group.startedAtS = now;
  group.lastFrameS = now;
  group.frameClockAnchored = false;
  for (GroupMemberAnimation &member : group.members) {
    member.animation.startedAtS = now;
    member.animation.lastFrameS = now;
    member.animation.frameClockAnchored = false;
  }
  startGroupFrameLoop(group);
}

void reconcileGroupReadiness(uint64_t driverId) {
  const auto stateIterator = registry().find(driverId);
  if (stateIterator == registry().end() || stateIterator->second.groupId == 0) {
    return;
  }
  const int32_t groupId = stateIterator->second.groupId;
  auto groupIterator = groupRegistry().find(groupId);
  if (groupIterator == groupRegistry().end()) {
    stateIterator->second.groupId = 0;
    return;
  }
  ActiveGroup &group = groupIterator->second;
  const bool ready = allGroupMembersReady(group);
  if (!group.started) {
    if (ready) startPendingGroup(group);
    return;
  }
  if (ready) return;
  finishGroupImpl(groupId, false, false);
}

// Starts a pre-ready animation with its full duration, then joins the
// choreographer loop.
void startPendingAnimation(uint64_t driverId, DriverState &state) {
  auto &animation = *state.animation;
  animation.started = true;
  animation.startedAtS = nowSeconds();
  animation.lastFrameS = animation.startedAtS;
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
  setAutonomousMotion(state, true);
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
  // a hint (NaN: unstamped callers, tests, iOS ignoring the field)
  // this reduces exactly to the old nowSeconds() + min() anchor path.
  const double wallNow = nowSeconds();
  const StartStamp stamp = resolveStartStamp(startedAtHintS, wallNow);
  animation.startedAtS = stamp.startedAtS;
  animation.lastFrameS = stamp.startedAtS;
  animation.frameClockAnchored = stamp.frameClockAnchored;
  // current = start while pre-ready is load-bearing: cancelAnimation,
  // beginInteraction, prepareAnimation's visibleBefore and registerView's
  // visible all read animation->current, giving a never-rendered pending-run
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
    // No host can display yet (animateTo raced the mount, or the host is
    // detached/unsized). The first displayable registration, host-geometry
    // push, or window attach starts the full clock, joins
    // animatingDrivers() and schedules the frame loop. Non-zero id is still
    // returned so the JS side does not treat this as rejection.
    return state.animation->id;
  }
  auto &active = animatingDrivers();
  if (std::find(active.begin(), active.end(), driverId) == active.end()) {
    active.push_back(driverId);
  }
  setAutonomousMotion(state, true);
  applyToViews(state, state.animation->start);
  scheduleFrame();
  return state.animation->id;
}

void finishIfHostUnavailable(uint64_t driverId, DriverState &state) {
  if (!state.animation.has_value() || !state.animation->started ||
      anyDisplayableView(state)) {
    return;
  }
  const Presentation target = state.animation->target;
  state.latest = target;
  state.hasLatest = true;
  state.ownership = Ownership::Interactive;
  applyToViews(state, target);
  finishActive(driverId, state, true);
}

void reconcileViewDisplayability(
    uint64_t driverId,
    DriverState &state,
    ViewEntry &entry) {
  if (!state.animation.has_value()) return;
  if (!state.animation->started) {
    if (entryDisplayable(entry)) startPendingAnimation(driverId, state);
    return;
  }

  if (entryDisplayable(entry)) {
    if (entry.participation != ViewParticipation::Active) {
      entry.participation = ViewParticipation::Active;
      deliverToView(entry, state.animation->current);
    }
  } else if (entry.participation == ViewParticipation::Active) {
    entry.participation = ViewParticipation::Deferred;
  }
  finishIfHostUnavailable(driverId, state);
}

void advance(uint64_t driverId, DriverState &state, double now) {
  ActiveAnimation &animation = *state.animation;

  if (!animation.frameClockAnchored) {
    // This is the unstamped/pre-ready fallback. Worklet-issued animations carry
    // Reanimated's exact `__frameTimestamp || _getAnimationTimestamp()` value
    // and arrive pre-anchored, so they skip this approximation — including the
    // CALLBACK_INPUT case where the current frame stamp predates the call.
    // Here startedAtS/lastFrameS hold nowSeconds() sampled at native
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
    animation.lastFrameS = now;
    const double fraction =
        timingFraction(now, animation.startedAtS, animation.durationS);
    const double eased = cubicBezier(
        animation.timing.controlPoint1X,
        animation.timing.controlPoint1Y,
        animation.timing.controlPoint2X,
        animation.timing.controlPoint2Y,
        fraction);
    animation.current = interpolate(animation.start, animation.target, eased);
    const bool canonical = canonicalizePresentation(animation.current);
    if (!canonical) {
      animation.current = animation.target;
    }
    done = !canonical || fraction >= 1.0;
  }
  // The completion branch below fans out the exact target; applying the
  // integrated value too would double every JNI crossing on the final frame.
  if (!done) applyAnimationFrameToViews(state, animation.current);

  if (done) {
    const int32_t animationId = animation.id;
    const int32_t completionTag = animation.completionTag;
    const Presentation target = animation.target;
    clearActiveAnimation(driverId, state);
    state.latest = target;
    state.hasLatest = true;
    state.ownership = Ownership::Interactive;
    applyToViews(state, target);
    emitCompletion(driverId, animationId, completionTag, true);
  }
}

void advanceGroup(int32_t groupId, ActiveGroup &group, double now) {
  if (!group.frameClockAnchored) {
    group.startedAtS = anchorStartTime(group.startedAtS, now);
    group.lastFrameS = group.startedAtS;
    group.frameClockAnchored = true;
    for (GroupMemberAnimation &member : group.members) {
      member.animation.startedAtS = group.startedAtS;
      member.animation.lastFrameS = group.startedAtS;
      member.animation.frameClockAnchored = true;
    }
  }

  bool done = false;
  if (group.kind == AnimationKind::Spring) {
    const double deltaTime = now - group.lastFrameS;
    group.lastFrameS = now;
    group.scalarSpring = advanceScalarSpring(
        group.scalarSpring, group.spring, deltaTime);
    done = relativeSpringEnergy(group.scalarSpring, group.spring) <=
        group.spring.energyThreshold;
    for (GroupMemberAnimation &member : group.members) {
      member.animation.current = interpolate(
          member.animation.start,
          member.animation.target,
          done ? 1.0 : group.scalarSpring.position);
      if (!canonicalizePresentation(member.animation.current)) {
        member.animation.current = member.animation.target;
        done = true;
      }
    }
  } else {
    group.lastFrameS = now;
    const double fraction =
        timingFraction(now, group.startedAtS, group.durationS);
    const double eased = cubicBezier(
        group.timing.controlPoint1X,
        group.timing.controlPoint1Y,
        group.timing.controlPoint2X,
        group.timing.controlPoint2Y,
        fraction);
    bool canonical = true;
    for (GroupMemberAnimation &member : group.members) {
      member.animation.lastFrameS = now;
      member.animation.current = interpolate(
          member.animation.start, member.animation.target, eased);
      if (!canonicalizePresentation(member.animation.current)) {
        member.animation.current = member.animation.target;
        canonical = false;
      }
    }
    done = !canonical || fraction >= 1.0;
  }

  if (done) {
    finishGroupImpl(groupId, true, true);
  } else {
    applyGroupCurrent(group);
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
  static std::vector<int32_t> groupScratch;
  groupScratch = animatingGroups();
  for (const int32_t groupId : groupScratch) {
    auto iterator = groupRegistry().find(groupId);
    if (iterator == groupRegistry().end() || !iterator->second.started) continue;
    advanceGroup(groupId, iterator->second, now);
  }
  if (!animatingDrivers().empty() || !animatingGroups().empty()) scheduleFrame();
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

void setGroupCompletionCallback(
    const void *owner,
    GroupCompletionCallback callback) {
  std::lock_guard<std::mutex> lock(completionSinkMutex());
  groupCompletionSink().owner = owner;
  groupCompletionSink().callback = std::move(callback);
}

void clearGroupCompletionCallback(const void *owner) {
  std::lock_guard<std::mutex> lock(completionSinkMutex());
  if (groupCompletionSink().owner != owner) return;
  groupCompletionSink().owner = nullptr;
  groupCompletionSink().callback = nullptr;
}

Presentation snapshotCurrent(uint64_t driverId) {
  if (!isOnMainThread()) return unavailablePresentation();
  const auto iterator = registry().find(driverId);
  if (iterator == registry().end() || iterator->second.destroyed ||
      !iterator->second.hasLatest) {
    return unavailablePresentation();
  }
  return visiblePresentation(driverId, iterator->second);
}

Presentation snapshotCurrentAndroid(uint64_t driverId) {
  return snapshotCurrent(driverId);
}

std::vector<DriverSnapshot> snapshotGroup(
    const std::vector<uint64_t> &driverIds) {
  std::vector<DriverSnapshot> snapshots;
  snapshots.reserve(driverIds.size());
  if (!isOnMainThread()) return snapshots;
  for (const uint64_t driverId : driverIds) {
    const auto iterator = registry().find(driverId);
    if (iterator == registry().end() || iterator->second.destroyed ||
        !iterator->second.hasLatest) {
      snapshots.push_back({driverId, unavailablePresentation(), false});
      continue;
    }
    const DriverState &state = iterator->second;
    snapshots.push_back(
        {driverId, visiblePresentation(driverId, state),
         anyDisplayableView(state)});
  }
  return snapshots;
}

std::vector<DriverSnapshot> beginGroupInteraction(
    const std::vector<uint64_t> &driverIds) {
  if (!isOnMainThread()) return {};
  std::vector<uint64_t> unique;
  unique.reserve(driverIds.size());
  for (const uint64_t driverId : driverIds) {
    if (driverId == 0 ||
        std::find(unique.begin(), unique.end(), driverId) != unique.end()) {
      return {};
    }
    const auto iterator = registry().find(driverId);
    if (iterator == registry().end() || iterator->second.destroyed ||
        !iterator->second.hasLatest) {
      return snapshotGroup(driverIds);
    }
    unique.push_back(driverId);
  }

  std::vector<int32_t> groupsToCancel;
  for (const uint64_t driverId : driverIds) {
    const int32_t groupId = registry().at(driverId).groupId;
    if (groupId != 0 &&
        std::find(groupsToCancel.begin(), groupsToCancel.end(), groupId) ==
            groupsToCancel.end()) {
      groupsToCancel.push_back(groupId);
    }
  }
  for (const int32_t groupId : groupsToCancel) {
    finishGroupImpl(groupId, false, false);
  }
  for (const uint64_t driverId : driverIds) {
    DriverState &state = registry().at(driverId);
    if (state.animation.has_value()) {
      const int32_t animationId = state.animation->id;
      const int32_t completionTag = state.animation->completionTag;
      const Presentation current = state.animation->current;
      clearActiveAnimation(driverId, state);
      state.latest = current;
      state.hasLatest = true;
      applyToViews(state, current);
      emitCompletion(driverId, animationId, completionTag, false);
    }
    state.ownership = Ownership::Interactive;
  }
  return snapshotGroup(driverIds);
}

bool setPresentationBatch(const std::vector<BatchEntry> &entries) {
  if (!isOnMainThread() || entries.empty()) return false;
  std::vector<BatchEntry> canonicalEntries = entries;
  for (BatchEntry &entry : canonicalEntries) {
    if (!canonicalizePresentation(entry.presentation)) return false;
  }
  std::vector<uint64_t> unique;
  std::vector<int32_t> groupsToCancel;
  unique.reserve(entries.size());
  for (const BatchEntry &entry : canonicalEntries) {
    if (entry.driverId == 0 ||
        std::find(unique.begin(), unique.end(), entry.driverId) != unique.end()) {
      return false;
    }
    const auto iterator = registry().find(entry.driverId);
    if (iterator == registry().end() || iterator->second.destroyed ||
        !isFinitePresentation(entry.presentation)) {
      return false;
    }
    if (iterator != registry().end() && iterator->second.groupId != 0 &&
        std::find(
            groupsToCancel.begin(),
            groupsToCancel.end(),
            iterator->second.groupId) == groupsToCancel.end()) {
      groupsToCancel.push_back(iterator->second.groupId);
    }
    unique.push_back(entry.driverId);
  }

  // Replacement is all-or-nothing: validation above is deliberately complete
  // before any old group is dissolved. An overlap dissolves the whole immutable
  // old group (including members absent from this batch) exactly once.
  for (const int32_t groupId : groupsToCancel) {
    finishGroupImpl(groupId, false, false);
  }

  const double now = nowSeconds();
  for (const BatchEntry &entry : canonicalEntries) {
    DriverState &state = registry().at(entry.driverId);
    state.destroyed = false;
    finishActive(entry.driverId, state, false);
    state.latest = entry.presentation;
    state.hasLatest = true;
    state.ownership = Ownership::Interactive;
    recordVelocitySample(
        state.samples, velocityChannels(entry.presentation), now);
  }
  for (const BatchEntry &entry : canonicalEntries) {
    applyToViews(registry().at(entry.driverId), entry.presentation);
  }
  return true;
}

namespace {

int32_t startGroupCommon(
    uint64_t controllerId,
    std::vector<GroupMotionEntry> entries,
    AnimationKind kind,
    TimingAnimation timing,
    SpringAnimation spring,
    double durationMs,
    int32_t reduceMotion,
    int32_t completionTag,
    double startedAtHintS) {
  if (!isOnMainThread() || controllerId == 0 || entries.empty()) {
    return 0;
  }
  for (GroupMotionEntry &entry : entries) {
    if ((entry.hasFrom && !canonicalizePresentation(entry.from)) ||
        !canonicalizePresentation(entry.target)) {
      return 0;
    }
  }
  if (kind == AnimationKind::Timing &&
      !isValidTiming(timing)) {
    return 0;
  }
  if (kind == AnimationKind::Spring &&
      (!isValidSpring(spring) || spring.inheritVelocity)) {
    return 0;
  }
  const bool reduce = shouldReduceMotion(reduceMotion) ||
      (kind != AnimationKind::Spring && durationMs <= 0);
  std::vector<uint64_t> unique;
  std::vector<int32_t> groupsToCancel;
  std::vector<Presentation> resolvedStarts;
  unique.reserve(entries.size());
  resolvedStarts.reserve(entries.size());
  for (const GroupMotionEntry &entry : entries) {
    if (entry.driverId == 0 ||
        std::find(unique.begin(), unique.end(), entry.driverId) != unique.end()) {
      return 0;
    }
    const auto iterator = registry().find(entry.driverId);
    if ((iterator == registry().end() || iterator->second.destroyed ||
         !iterator->second.hasLatest) && !entry.hasFrom) {
      return 0;
    }
    if (iterator != registry().end() && iterator->second.groupId != 0 &&
        std::find(
            groupsToCancel.begin(),
            groupsToCancel.end(),
            iterator->second.groupId) == groupsToCancel.end()) {
      groupsToCancel.push_back(iterator->second.groupId);
    }
    const Presentation resolvedStart = entry.hasFrom
        ? entry.from
        : visiblePresentation(entry.driverId, iterator->second);
    if (!isFinitePresentation(resolvedStart) ||
        !isFinitePresentation(entry.target) ||
        !isAutonomousUniformCircular(resolvedStart) ||
        !isAutonomousUniformCircular(entry.target)) {
      return 0;
    }
    if (kind == AnimationKind::Spring) {
      const double velocity = spring.initialVelocity;
      if (!springScaleStaysPositive(
              resolvedStart, entry.target, spring, velocity)) {
        return 0;
      }
    }
    resolvedStarts.push_back(resolvedStart);
    unique.push_back(entry.driverId);
  }

  // Capture every implicit start above, while overlapped groups still own
  // their current frames. Only after full preflight may replacement dissolve
  // those immutable groups and emit one unfinished completion for each.
  for (const int32_t groupId : groupsToCancel) {
    finishGroupImpl(groupId, false, false);
  }

  ActiveGroup group;
  group.controllerId = controllerId;
  group.id = allocateAnimationId();
  group.completionTag = completionTag;
  group.kind = kind;
  group.timing = timing;
  group.spring = spring;
  group.scalarSpring = {0, spring.initialVelocity};
  group.durationS = durationMs / 1000.0;
  group.members.reserve(entries.size());
  const double wallNow = nowSeconds();

  for (std::size_t entryIndex = 0; entryIndex < entries.size(); entryIndex += 1) {
    GroupMotionEntry &entry = entries[entryIndex];
    DriverState &state = registry()[entry.driverId];
    const Presentation resolvedStart = resolvedStarts[entryIndex];
    finishActive(entry.driverId, state, false);
    state.destroyed = false;
    state.latest = entry.target;
    state.hasLatest = true;
    state.ownership = Ownership::Native;
    state.groupId = group.id;

    GroupMemberAnimation member;
    member.driverId = entry.driverId;
    member.animation.id = group.id;
    member.animation.kind = kind;
    member.animation.start = resolvedStart;
    member.animation.target = entry.target;
    member.animation.current = resolvedStart;
    member.animation.timing = timing;
    member.animation.spring = spring;
    member.animation.durationS = group.durationS;
    group.members.push_back(std::move(member));
  }

  // Apply every explicit start after the whole participant set has passed
  // preflight and acquired the new immutable group id. This remains one
  // synchronous main-thread transaction even when the initial readiness
  // barrier is pending; ready hosts must not keep displaying their old frame
  // while snapshots already report `from`.
  for (std::size_t entryIndex = 0; entryIndex < entries.size(); entryIndex += 1) {
    if (!entries[entryIndex].hasFrom) continue;
    applyToViews(
        registry().at(entries[entryIndex].driverId),
        resolvedStarts[entryIndex]);
  }

  const int32_t groupId = group.id;
  const StartStamp stamp = resolveStartStamp(startedAtHintS, wallNow);
  group.startedAtS = stamp.startedAtS;
  group.lastFrameS = stamp.startedAtS;
  group.frameClockAnchored = stamp.frameClockAnchored;
  for (GroupMemberAnimation &member : group.members) {
    member.animation.startedAtS = stamp.startedAtS;
    member.animation.lastFrameS = stamp.startedAtS;
    member.animation.frameClockAnchored = stamp.frameClockAnchored;
  }
  group.started = allGroupMembersReady(group);
  groupRegistry().emplace(groupId, std::move(group));
  if (reduce) {
    finishGroupImpl(groupId, true, true);
    return groupId;
  }
  ActiveGroup &stored = groupRegistry().at(groupId);
  if (stored.started) {
    startGroupFrameLoop(stored);
  }
  return groupId;
}

} // namespace

int32_t animateTimingGroup(
    uint64_t controllerId,
    std::vector<GroupMotionEntry> entries,
    TimingAnimation animation,
    int32_t completionTag,
    double startedAtHintS) {
  return startGroupCommon(
      controllerId,
      std::move(entries),
      AnimationKind::Timing,
      animation,
      {},
      animation.durationMs,
      animation.reduceMotion,
      completionTag,
      startedAtHintS);
}

int32_t animateSpringGroup(
    uint64_t controllerId,
    std::vector<GroupMotionEntry> entries,
    SpringAnimation animation,
    int32_t completionTag,
    double startedAtHintS) {
  return startGroupCommon(
      controllerId,
      std::move(entries),
      AnimationKind::Spring,
      {},
      animation,
      kSpringMaxDurationS * 1000.0,
      animation.reduceMotion,
      completionTag,
      startedAtHintS);
}

std::vector<DriverSnapshot> cancelAnimationGroup(
    int32_t groupId,
    GroupCancelBehavior behavior) {
  if (!isOnMainThread()) return {};
  const bool finish = behavior == GroupCancelBehavior::Finish;
  return finishGroupImpl(
      groupId, finish, finish);
}

void setPresentation(
    uint64_t driverId,
    Presentation presentation,
    bool takeOwnership,
    bool overridePendingAnimation,
    bool recordVelocity) {
  if (!isOnMainThread()) return;
  if (!canonicalizePresentation(presentation)) return;
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
  if (state.groupId != 0) {
    if (!takeOwnership) return;
    finishGroupImpl(state.groupId, false, false);
  }
  if (!takeOwnership && state.ownership != Ownership::Interactive) return;
  if (takeOwnership) {
    state.destroyed = false;
    // Passive seeds and public setters must not displace newer pending intent.
    // The fused animation.from write is different: it is the caller's newest,
    // authoritative start and explicitly cancels the pending run.
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
    recordVelocitySample(
        state.samples, velocityChannels(presentation), nowSeconds());
  } else if (state.samples.hasLatest) {
    // Untracked movement invalidates the recorded velocity pair.
    clearVelocitySamples(state.samples);
  }
  applyToViews(state, presentation);
}

Presentation beginInteraction(uint64_t driverId) {
  if (!isOnMainThread()) return unavailablePresentation();
  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return unavailablePresentation();
  auto &state = iterator->second;
  if (state.groupId != 0) {
    finishGroupImpl(state.groupId, false, false);
  }
  state.destroyed = false;
  if (!state.animation.has_value()) {
    state.ownership = Ownership::Interactive;
    return state.latest;
  }
  const int32_t animationId = state.animation->id;
  const int32_t completionTag = state.animation->completionTag;
  const Presentation current = state.animation->current;
  clearActiveAnimation(driverId, state);
  state.latest = current;
  state.hasLatest = true;
  state.ownership = Ownership::Interactive;
  // The frozen frame came from native animation movement, not an interactive
  // write. Do not let it become a later `initialVelocity: inherit` sample.
  applyToViews(state, current);
  emitCompletion(driverId, animationId, completionTag, false);
  return current;
}

int32_t animateTiming(
    uint64_t driverId,
    AnimationStart start,
    Presentation presentation,
    TimingAnimation animation,
    int32_t completionTag) {
  const bool validAnimation = isValidTiming(animation);
  if (!canonicalizePresentation(presentation) ||
      (start.hasInteractiveStart &&
       !canonicalizePresentation(start.interactiveStart))) {
    return 0;
  }
  if (!isOnMainThread() || driverId == 0 ||
      !isFinitePresentation(presentation) || !validAnimation) {
    return 0;
  }
  auto iterator = registry().find(driverId);
  Presentation preflightStart;
  if (iterator == registry().end()) {
    if (!start.hasInteractiveStart ||
        !isFinitePresentation(start.interactiveStart)) {
      return 0;
    }
    preflightStart = start.interactiveStart;
  } else {
    if (iterator->second.destroyed && !start.hasInteractiveStart) return 0;
    preflightStart = start.hasInteractiveStart
        ? start.interactiveStart
        : visiblePresentation(driverId, iterator->second);
  }
  if (!isFinitePresentation(preflightStart) ||
      preflightStart.clip.curve != presentation.clip.curve) {
    return 0;
  }
  const bool reduce = shouldReduceMotion(animation.reduceMotion) ||
      animation.durationMs <= 0;
  if (iterator == registry().end()) {
    iterator = registry().try_emplace(driverId).first;
    iterator->second.latest = start.interactiveStart;
    iterator->second.hasLatest = true;
  }
  auto &state = iterator->second;
  if (state.groupId != 0) finishGroupImpl(state.groupId, false, false);
  state.destroyed = false;
  const int32_t animationId = allocateAnimationId();
  const Presentation resolvedStart =
      prepareAnimation(driverId, state, start, presentation);
  if (reduce) {
    applyPresentation(state, presentation);
    emitCompletion(driverId, animationId, completionTag, true);
    return animationId;
  }
  ActiveAnimation active;
  active.id = animationId;
  active.completionTag = completionTag;
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
    SpringAnimation animation,
    int32_t completionTag) {
  const bool validAnimation = isValidSpring(animation);
  if (!canonicalizePresentation(presentation) ||
      (start.hasInteractiveStart &&
       !canonicalizePresentation(start.interactiveStart))) {
    return 0;
  }
  if (!isOnMainThread() || driverId == 0 ||
      !isFinitePresentation(presentation) || !validAnimation) {
    return 0;
  }
  auto iterator = registry().find(driverId);
  Presentation preflightStart;
  if (iterator == registry().end()) {
    if (!start.hasInteractiveStart ||
        !isFinitePresentation(start.interactiveStart)) {
      return 0;
    }
    preflightStart = start.interactiveStart;
  } else {
    if (iterator->second.destroyed && !start.hasInteractiveStart) return 0;
    preflightStart = start.hasInteractiveStart
        ? start.interactiveStart
        : visiblePresentation(driverId, iterator->second);
  }
  const double velocity = animation.inheritVelocity &&
          iterator != registry().end()
      ? inheritedVelocity(
            iterator->second.samples,
            velocityChannels(presentation),
            nowSeconds())
      : animation.initialVelocity;
  if (!isFinitePresentation(preflightStart) ||
      preflightStart.clip.curve != presentation.clip.curve ||
      !springScaleStaysPositive(
          preflightStart, presentation, animation, velocity)) {
    return 0;
  }
  if (iterator == registry().end()) {
    iterator = registry().try_emplace(driverId).first;
    iterator->second.latest = start.interactiveStart;
    iterator->second.hasLatest = true;
  }
  auto &state = iterator->second;
  if (state.groupId != 0) finishGroupImpl(state.groupId, false, false);
  state.destroyed = false;
  const int32_t animationId = allocateAnimationId();
  // Scalar velocity along the current-to-target trajectory; each channel is
  // seeded with velocity·displacement to match the iOS CASpringAnimation
  // per-keypath behavior.
  const Presentation resolvedStart =
      prepareAnimation(driverId, state, start, presentation);
  if (shouldReduceMotion(animation.reduceMotion)) {
    applyPresentation(state, presentation);
    emitCompletion(driverId, animationId, completionTag, true);
    return animationId;
  }
  ActiveAnimation active;
  active.id = animationId;
  active.completionTag = completionTag;
  active.kind = AnimationKind::Spring;
  active.spring = animation;
  active.spring.initialVelocity = velocity;
  active.spring.inheritVelocity = false;
  active.start = resolvedStart;
  active.target = presentation;
  active.durationS = kSpringMaxDurationS;
  const auto normalizedEndpoints = normalizeShadowEndpoints(
      resolvedStart, presentation);
  const auto startChannels = toChannels(normalizedEndpoints.first);
  const auto targetChannels = toChannels(normalizedEndpoints.second);
  active.springChannelCount =
      (resolvedStart.shadow.enabled && resolvedStart.shadow.alpha > 0) ||
          (presentation.shadow.enabled && presentation.shadow.alpha > 0)
      ? kChannelCount
      : kBaseChannelCount;
  active.springPosition = startChannels;
  for (std::size_t index = 0;
       index < active.springChannelCount;
       index += 1) {
    active.springVelocity[index] =
        velocity * (targetChannels[index] - startChannels[index]);
  }
  return startAnimation(driverId, state, std::move(active), start.startedAtHintS);
}

int32_t rejectAnimation(uint64_t driverId) {
  if (!isOnMainThread()) return 0;
  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return 0;
  const int32_t animationId = allocateAnimationId();
  emitCompletion(driverId, animationId, 0, false);
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
  if (state.groupId != 0) {
    const int32_t activeGroupId = state.groupId;
    if (animationId > 0 && animationId != activeGroupId) {
      return {false, visiblePresentation(driverId, state)};
    }
    const std::vector<DriverSnapshot> snapshots =
        finishGroupImpl(activeGroupId, useTarget, false);
    for (const DriverSnapshot &snapshot : snapshots) {
      if (snapshot.driverId == driverId) return {true, snapshot.presentation};
    }
    return {false, unavailablePresentation()};
  }
  if (!state.animation.has_value() ||
      (animationId > 0 && animationId != state.animation->id)) {
    return {false, state.animation.has_value() ? state.animation->current
                                               : state.latest};
  }
  const Presentation result =
      useTarget ? state.animation->target : state.animation->current;
  const int32_t activeId = state.animation->id;
  const int32_t completionTag = state.animation->completionTag;
  clearActiveAnimation(driverId, state);
  state.latest = result;
  state.hasLatest = true;
  state.ownership = Ownership::Interactive;
  applyToViews(state, result);
  emitCompletion(driverId, activeId, completionTag, false);
  return {true, result};
}

void destroyDriver(uint64_t driverId) {
  if (!isOnMainThread()) return;
  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return;
  auto &state = iterator->second;
  if (state.groupId != 0) finishGroupImpl(state.groupId, false, false);
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
              jdouble,
              jdouble,
              jdouble,
              jdouble,
              jdouble,
              jdouble,
              jdouble,
              jdouble,
              jint,
              jdouble,
              jdouble,
              jdouble,
              jboolean,
              jdouble,
              jdouble,
              jdouble,
              jdouble,
              jdouble,
              jdouble,
              jdouble,
              jdouble)>("setClipPresentationDip");
  method(
      self(),
      presentation.clip.x,
      presentation.clip.y,
      presentation.clip.width,
      presentation.clip.height,
      SmoothClipResolvedRadius(
          presentation.clip.topLeftRadius, presentation.clip.radius),
      SmoothClipResolvedRadius(
          presentation.clip.topRightRadius, presentation.clip.radius),
      SmoothClipResolvedRadius(
          presentation.clip.bottomRightRadius, presentation.clip.radius),
      SmoothClipResolvedRadius(
          presentation.clip.bottomLeftRadius, presentation.clip.radius),
      static_cast<jint>(presentation.clip.curve),
      presentation.contentTranslateX,
      presentation.contentTranslateY,
      presentation.contentScale,
      presentation.shadow.enabled,
      presentation.shadow.red,
      presentation.shadow.green,
      presentation.shadow.blue,
      presentation.shadow.alpha,
      presentation.shadow.offsetX,
      presentation.shadow.offsetY,
      presentation.shadow.blurRadius,
      presentation.shadow.spreadDistance);
}

void JSmoothClipView::applyClipPx(
    const CanonicalClip &clip,
    double contentTranslateXPx,
    double contentTranslateYPx,
    double contentScale,
    const Shadow &shadowPx) const {
  static const auto method =
      javaClassStatic()
          ->getMethod<void(
              jfloat,
              jfloat,
              jfloat,
              jfloat,
              jfloat,
              jfloat,
              jfloat,
              jfloat,
              jint,
              jfloat,
              jfloat,
              jfloat,
              jboolean,
              jfloat,
              jfloat,
              jfloat,
              jfloat,
              jfloat,
              jfloat,
              jfloat,
              jfloat)>("setClipPresentationPx");
  method(
      self(),
      static_cast<jfloat>(clip.left),
      static_cast<jfloat>(clip.top),
      static_cast<jfloat>(clip.right),
      static_cast<jfloat>(clip.bottom),
      static_cast<jfloat>(clip.topLeftRadius),
      static_cast<jfloat>(clip.topRightRadius),
      static_cast<jfloat>(clip.bottomRightRadius),
      static_cast<jfloat>(clip.bottomLeftRadius),
      static_cast<jint>(clip.curve),
      static_cast<jfloat>(contentTranslateXPx),
      static_cast<jfloat>(contentTranslateYPx),
      static_cast<jfloat>(contentScale),
      shadowPx.enabled,
      static_cast<jfloat>(shadowPx.red),
      static_cast<jfloat>(shadowPx.green),
      static_cast<jfloat>(shadowPx.blue),
      static_cast<jfloat>(shadowPx.alpha),
      static_cast<jfloat>(shadowPx.offsetX),
      static_cast<jfloat>(shadowPx.offsetY),
      static_cast<jfloat>(shadowPx.blurRadius),
      static_cast<jfloat>(shadowPx.spreadDistance));
}

void JSmoothClipView::setAutonomousMotion(bool active) const {
  static const auto method =
      javaClassStatic()->getMethod<void(jboolean)>("setAutonomousMotion");
  method(self(), active);
}

void registerViewAndroid(
    uint64_t driverId,
    alias_ref<JSmoothClipView> view,
    Presentation initialPresentation,
    double density,
    double hostWidthPx,
    double hostHeightPx,
    bool lifecycleVisible) {
  if (!canonicalizePresentation(initialPresentation)) return;
  auto &state = registry()[driverId];
  state.destroyed = false;
  if (!state.hasLatest) {
    state.latest = initialPresentation;
    state.hasLatest = true;
  }
  const Presentation visible = visiblePresentation(driverId, state);
  JNIEnv *env = facebook::jni::Environment::current();
  for (auto &existing : state.views) {
    if (env->IsSameObject(existing.view.get(), view.get())) {
      existing.density = density;
      existing.hostWidthPx = hostWidthPx;
      existing.hostHeightPx = hostHeightPx;
      existing.lifecycleVisible = lifecycleVisible;
      deliverToView(existing, visible);
      reconcileViewDisplayability(driverId, state, existing);
      reconcileGroupReadiness(driverId);
      return;
    }
  }
  // The public controller contract permits one simultaneous host. The React
  // wrapper reports this as a development error; native also refuses a second
  // host so release behavior cannot silently fan one controller out.
  if (!state.views.empty()) return;
  ViewEntry entry{
      facebook::jni::make_global(view),
      density,
      hostWidthPx,
      hostHeightPx,
      lifecycleVisible,
      ViewParticipation::Deferred};
  // `visible` already contains the start of a pre-ready animation.
  deliverToView(entry, visible);
  state.views.push_back(std::move(entry));
  reconcileViewDisplayability(driverId, state, state.views.back());
  reconcileGroupReadiness(driverId);
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
      deliverToView(entry, visiblePresentation(driverId, state));
    }
    reconcileViewDisplayability(driverId, state, entry);
    reconcileGroupReadiness(driverId);
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
    reconcileGroupReadiness(driverId);
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
      finishIfHostUnavailable(driverId, state);
    }
  }
  if (removed && state.groupId != 0 && isOnMainThread()) {
    reconcileGroupReadiness(driverId);
  }
  if (state.destroyed && state.views.empty()) {
    registry().erase(iterator);
  }
}

} // namespace smoothclip
