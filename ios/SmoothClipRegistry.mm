#import "SmoothClipViewRegistry.h"

#import "SmoothClipView.h"

#import <React/RCTUtils.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#if defined(SMOOTH_CLIP_ENABLE_SIGNPOSTS) && SMOOTH_CLIP_ENABLE_SIGNPOSTS
#import <os/signpost.h>
#endif

#include <algorithm>
#include <cmath>
#include <limits>
#include <mutex>
#include <optional>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include "SmoothClipAnimationId.h"
#include "SmoothClipAnimationCurve.h"
#include "SmoothClipSharedGeometry.h"

@interface SmoothClipView (Registry)
- (void)smoothClipApplyPresentation:(smoothclip::Presentation)presentation;
- (void)smoothClipApplyPresentation:(smoothclip::Presentation)presentation
               recordVelocitySample:(BOOL)recordVelocitySample;
- (smoothclip::Presentation)smoothClipFreezePresentation;
- (smoothclip::Presentation)smoothClipCurrentPresentation;
- (BOOL)smoothClipAnimateTiming:(smoothclip::Presentation)presentation
                       animation:(smoothclip::TimingAnimation)animation
                     animationId:(int32_t)animationId;
- (BOOL)smoothClipAnimateTiming:(smoothclip::Presentation)presentation
                       animation:(smoothclip::TimingAnimation)animation
                     animationId:(int32_t)animationId
                 sharedBeginTime:(CFTimeInterval)sharedBeginTime;
- (BOOL)smoothClipAnimateSpring:(smoothclip::Presentation)presentation
                       animation:(smoothclip::SpringAnimation)animation
                     animationId:(int32_t)animationId;
- (BOOL)smoothClipAnimateSpring:(smoothclip::Presentation)presentation
                       animation:(smoothclip::SpringAnimation)animation
                     animationId:(int32_t)animationId
                 sharedBeginTime:(CFTimeInterval)sharedBeginTime;
- (BOOL)smoothClipAnimateKeyframes:(smoothclip::Presentation)presentation
                         keyframes:(const std::vector<smoothclip::Keyframe> &)keyframes
                         durationMs:(double)durationMs
                        animationId:(int32_t)animationId;
- (BOOL)smoothClipAnimateKeyframes:(smoothclip::Presentation)presentation
                         keyframes:(const std::vector<smoothclip::Keyframe> &)keyframes
                         durationMs:(double)durationMs
                        animationId:(int32_t)animationId
                    sharedBeginTime:(CFTimeInterval)sharedBeginTime;
- (void)smoothClipCancelAnimationUsingTarget:(BOOL)useTarget;
- (BOOL)smoothClipIsJoinable;
- (BOOL)smoothClipCanDisplay;
- (BOOL)smoothClipHasPendingInstall;
- (double)smoothClipSpringContinuationVelocity;
- (void)smoothClipClearVelocitySamples;
@end

namespace smoothclip {
namespace {

using ViewKey = uintptr_t;

enum class Ownership { Interactive, Native };
enum class AnimationKind { Timing, Spring, Keyframes };

struct ActiveAnimation {
  int32_t animationId;
  // Zero identifies a single-driver animation. A non-zero value binds
  // the driver to an immutable group whose completion is aggregated once.
  int32_t groupId = 0;
  std::unordered_set<ViewKey> participants;
  // Hosts that installed this id and temporarily lost displayability. They
  // may rejoin the same remainder; completion is false if any remain
  // unresolved when the run ends or unregister.
  std::unordered_set<ViewKey> suspendedParticipants;
  bool finished = true;
  AnimationKind kind = AnimationKind::Timing;
  // Geometry the transition started from. Used when a view must join the
  // animation but there is no laid-out peer to sample presentation from.
  Presentation start{{0, 0, 0, 0, 0}, 0, 0};
  TimingAnimation timing{};
  SpringAnimation spring{};
  std::vector<Keyframe> keyframes;
  double durationMs = 0;
  CFTimeInterval startedAt = 0;
  // False while the animation is latched. Two ways in: built before any host
  // view could display (pre-registration, or a host in a detached subtree), or
  // re-latched by unregisterView when the last DISPLAYABLE host left
  // mid-flight. Started by whichever registration/displayability update or
  // joinActiveAnimation first finds a host that can produce a frame; each
  // rebases startedAt through startLatchedAnimation. startedAt is only
  // meaningful once started.
  bool started = false;
};

struct DriverState {
  Presentation latest{{0, 0, 0, 0, 0}, 0, 0};
  bool hasLatest = false;
  Ownership ownership = Ownership::Interactive;
  std::vector<ViewKey> views;
  std::optional<ActiveAnimation> animation;
  // Set by destroyDriver while views are still registered (StrictMode effect
  // replay, hosts mounted in another subtree). The entry is erased when the
  // last view leaves and revived by a take-ownership setPresentation.
  bool destroyed = false;
};

struct CompletionSink {
  const void *owner = nullptr;
  CompletionCallback callback;
};

struct GroupCompletionSink {
  const void *owner = nullptr;
  GroupCompletionCallback callback;
};

struct GroupState {
  uint64_t controllerId;
  int32_t groupId;
  std::vector<uint64_t> driverIds;
  std::unordered_set<uint64_t> remainingDriverIds;
  GroupSuspensionPolicy suspensionPolicy = GroupSuspensionPolicy::Pause;
  bool finished = true;
  bool mutating = false;
};

std::unordered_map<uint64_t, DriverState> &registry() {
  static std::unordered_map<uint64_t, DriverState> value;
  return value;
}

std::unordered_map<int32_t, GroupState> &groupRegistry() {
  static std::unordered_map<int32_t, GroupState> value;
  return value;
}

// The transitions must be observed for the whole process lifetime, not per
// view: the state below is process-global, and a notification delivered while
// no SmoothClipView happens to be alive (the last host unmounted during
// inactivity, or the app backgrounded between screens) must still land.
// View-held observers die with their views and left the flag permanently
// stale in exactly those windows.
void installApplicationStateObservers() {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UIApplicationWillResignActiveNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *) {
                      applicationWillResignActive();
                    }];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *) {
                      applicationDidBecomeActive();
                    }];
  });
}

bool &applicationActiveState() {
  installApplicationStateObservers();
  // The first SmoothClipView can be created after the app already entered the
  // background, too late to observe WillResignActive. Seed from UIKit rather
  // than assuming foreground so that first registration cannot start offscreen.
  static bool active = UIApplication.sharedApplication.applicationState ==
      UIApplicationStateActive;
  return active;
}

CompletionSink &completionSink() {
  static CompletionSink sink;
  return sink;
}

GroupCompletionSink &groupCompletionSink() {
  static GroupCompletionSink sink;
  return sink;
}

// The sink is written from the TurboModule ctor/dtor on the JS thread and
// invoked on main. Invoking under the lock also keeps the owning module
// alive for the duration of the callback.
std::mutex &completionSinkMutex() {
  static std::mutex value;
  return value;
}


void groupMemberCompleted(
    int32_t groupId,
    uint64_t driverId,
    bool finished);
std::vector<DriverSnapshot> cancelGroupInternal(
    int32_t groupId,
    GroupCancelBehavior behavior,
    bool completionFinished);
void tryStartGroup(int32_t groupId);
void suspendGroup(int32_t groupId);

Presentation unavailablePresentation() {
  // Non-finite geometry makes the JS side fall back to its current value
  // instead of applying zeros.
  return {{NAN, NAN, NAN, NAN, NAN}, NAN, NAN};
}

#if defined(SMOOTH_CLIP_ENABLE_SIGNPOSTS) && SMOOTH_CLIP_ENABLE_SIGNPOSTS
os_log_t signpostLog() {
  static os_log_t log = os_log_create(
      "com.smoothclipview", "clip-driver");
  return log;
}
#endif

ViewKey keyForView(SmoothClipView *view) {
  return reinterpret_cast<ViewKey>((__bridge void *)view);
}

SmoothClipView *viewForKey(ViewKey key) {
  return (__bridge SmoothClipView *)(reinterpret_cast<void *>(key));
}

bool shouldReduceMotion(int32_t setting) {
  return setting == 1 ||
      (setting == 0 && UIAccessibilityIsReduceMotionEnabled());
}

void emitCompletion(
    uint64_t driverId,
    DriverState &state,
    int32_t animationId,
    bool finished) {
  const int32_t groupId = state.animation.has_value()
      ? state.animation->groupId
      : 0;
  state.animation.reset();
  if (groupId != 0) {
    groupMemberCompleted(groupId, driverId, finished);
    return;
  }
  {
    std::lock_guard<std::mutex> lock(completionSinkMutex());
    if (completionSink().callback) {
      completionSink().callback(driverId, animationId, finished);
    }
  }
#if defined(SMOOTH_CLIP_ENABLE_SIGNPOSTS) && SMOOTH_CLIP_ENABLE_SIGNPOSTS
  os_signpost_event_emit(
      signpostLog(), OS_SIGNPOST_ID_EXCLUSIVE, "completion",
      "driver=%llu animation=%d finished=%{public}d",
      driverId, animationId, finished);
#endif
}

void emitGroupCompletion(
    uint64_t controllerId,
    int32_t groupId,
    bool finished,
    const std::vector<uint64_t> &driverIds) {
  std::lock_guard<std::mutex> lock(completionSinkMutex());
  if (groupCompletionSink().callback) {
    groupCompletionSink().callback(
        controllerId, groupId, finished, driverIds);
  }
}

void groupMemberCompleted(
    int32_t groupId,
    uint64_t driverId,
    bool finished) {
  auto iterator = groupRegistry().find(groupId);
  if (iterator == groupRegistry().end()) return;
  GroupState &group = iterator->second;
  if (group.remainingDriverIds.erase(driverId) == 0) return;
  group.finished = group.finished && finished;
  if (!group.remainingDriverIds.empty() || group.mutating) return;

  const uint64_t controllerId = group.controllerId;
  const bool aggregateFinished = group.finished;
  const std::vector<uint64_t> driverIds = group.driverIds;
  groupRegistry().erase(iterator);
  emitGroupCompletion(
      controllerId, groupId, aggregateFinished, driverIds);
}

void emitStandaloneCompletion(
    uint64_t driverId,
    int32_t animationId,
    bool finished) {
  {
    std::lock_guard<std::mutex> lock(completionSinkMutex());
    if (completionSink().callback) {
      completionSink().callback(driverId, animationId, finished);
    }
  }
#if defined(SMOOTH_CLIP_ENABLE_SIGNPOSTS) && SMOOTH_CLIP_ENABLE_SIGNPOSTS
  os_signpost_event_emit(
      signpostLog(), OS_SIGNPOST_ID_EXCLUSIVE, "completion",
      "driver=%llu animation=%d finished=%{public}d",
      driverId, animationId, finished);
#endif
}

Presentation canonicalFrozenPresentation(
    DriverState &state,
    SmoothClipView *preferred = nil) {
  // A latched animation never rendered, so state.latest already holds its
  // target; freezing there would jump the clip. Freeze at the start instead.
  Presentation canonical =
      state.animation.has_value() && !state.animation->started
      ? state.animation->start
      : state.latest;
  bool hasCanonical = false;
  bool hasParticipantFallback = false;
  Presentation participantFallback{{0, 0, 0, 0, 0}, 0, 0};
  for (const ViewKey key : state.views) {
    // Freeze every view (the teardown side effect must reach all of them),
    // but only a laid-out view may define the canonical geometry — an
    // unlaid-out one reports {0,0,0,0} and would collapse the clip.
    SmoothClipView *candidate = viewForKey(key);
    const Presentation frozen = [candidate smoothClipFreezePresentation];
    if (candidate == preferred && [candidate smoothClipIsJoinable]) {
      canonical = frozen;
      hasCanonical = true;
    } else if (!hasCanonical && [candidate smoothClipIsJoinable]) {
      canonical = frozen;
      hasCanonical = true;
    } else if (!hasParticipantFallback && state.animation.has_value() &&
               (state.animation->participants.count(key) > 0 ||
                state.animation->suspendedParticipants.count(key) > 0)) {
      // An installed participant whose HOST just lost its size still holds
      // real mid-flight geometry on its clip layer (host bounds do not feed
      // the clip container). Without this fallback, a sole running host
      // resized to zero froze the re-latch at state.latest — the target —
      // and the resumed animation snapped to its endpoint.
      hasParticipantFallback = true;
      participantFallback = frozen;
    }
  }
  if (!hasCanonical && hasParticipantFallback) {
    canonical = participantFallback;
  }
  return canonical;
}

Presentation canonicalVisiblePresentation(const DriverState &state) {
  if (state.animation.has_value() && !state.animation->started) {
    return state.animation->start;
  }
  for (const ViewKey key : state.views) {
    SmoothClipView *candidate = viewForKey(key);
    if ([candidate smoothClipIsJoinable]) {
      return [candidate smoothClipCurrentPresentation];
    }
  }
  return state.latest;
}

bool driverReady(const DriverState &state) {
  if (state.destroyed) return false;
  for (const ViewKey key : state.views) {
    if ([viewForKey(key) smoothClipCanDisplay]) return true;
  }
  return false;
}

DriverSnapshot snapshotForDriver(uint64_t driverId) {
  const auto iterator = registry().find(driverId);
  if (iterator == registry().end() || iterator->second.destroyed) {
    return {driverId, unavailablePresentation(), false};
  }
  return {
      driverId,
      canonicalVisiblePresentation(iterator->second),
      driverReady(iterator->second),
  };
}

std::vector<DriverSnapshot> cancelGroupInternal(
    int32_t groupId,
    GroupCancelBehavior behavior,
    bool completionFinished) {
  auto groupIterator = groupRegistry().find(groupId);
  if (groupIterator == groupRegistry().end()) return {};
  GroupState &group = groupIterator->second;
  if (group.mutating) return {};
  group.mutating = true;

  const std::vector<uint64_t> driverIds = group.driverIds;
  std::vector<DriverSnapshot> snapshots;
  snapshots.reserve(driverIds.size());
  for (const uint64_t driverId : driverIds) {
    auto stateIterator = registry().find(driverId);
    if (stateIterator == registry().end()) {
      snapshots.push_back({driverId, unavailablePresentation(), false});
      groupMemberCompleted(groupId, driverId, false);
      continue;
    }
    DriverState &state = stateIterator->second;
    if (!state.animation.has_value() ||
        state.animation->groupId != groupId) {
      snapshots.push_back(snapshotForDriver(driverId));
      groupMemberCompleted(groupId, driverId, false);
      continue;
    }

    const int32_t animationId = state.animation->animationId;
    Presentation resolved;
    if (behavior == GroupCancelBehavior::Finish) {
      resolved = state.latest;
      const bool wasLatched = !state.animation->started;
      for (const ViewKey key : state.views) {
        [viewForKey(key) smoothClipCancelAnimationUsingTarget:YES];
      }
      if (wasLatched) {
        for (const ViewKey key : state.views) {
          [viewForKey(key) smoothClipApplyPresentation:resolved
                                  recordVelocitySample:NO];
        }
      }
    } else {
      resolved = canonicalFrozenPresentation(state);
    }
    state.latest = resolved;
    state.hasLatest = true;
    state.ownership = Ownership::Interactive;
    const bool ready = driverReady(state);
    emitCompletion(
        driverId, state, animationId, completionFinished);
    snapshots.push_back({driverId, resolved, ready});
  }

  groupIterator = groupRegistry().find(groupId);
  if (groupIterator != groupRegistry().end()) {
    GroupState &remainingGroup = groupIterator->second;
    remainingGroup.mutating = false;
    if (remainingGroup.remainingDriverIds.empty()) {
      const uint64_t controllerId = remainingGroup.controllerId;
      const bool finished = remainingGroup.finished;
      const std::vector<uint64_t> completedDrivers =
          remainingGroup.driverIds;
      groupRegistry().erase(groupIterator);
      emitGroupCompletion(
          controllerId, groupId, finished, completedDrivers);
    }
  }
  return snapshots;
}

void cancelActive(
    uint64_t driverId,
    DriverState &state,
    bool useTarget) {
  if (!state.animation.has_value()) return;
  if (state.animation->groupId != 0) {
    cancelGroupInternal(
        state.animation->groupId,
        useTarget ? GroupCancelBehavior::Finish
                  : GroupCancelBehavior::Freeze,
        false);
    return;
  }
  const int32_t animationId = state.animation->animationId;
  // Deferred views are deliberately not completion participants, but they do
  // hold a pending install and requested target. Cancellation must still reach
  // every registered view so a later attach cannot resurrect the old id.
  for (const ViewKey key : state.views) {
    [viewForKey(key) smoothClipCancelAnimationUsingTarget:useTarget];
  }
  emitCompletion(driverId, state, animationId, false);
}

void finishIfNoInstalledParticipants(uint64_t driverId, DriverState &state) {
  if (!state.animation.has_value() || !state.animation->started ||
      !state.animation->participants.empty()) {
    return;
  }
  const int32_t animationId = state.animation->animationId;
  const bool finished = state.animation->finished &&
      state.animation->suspendedParticipants.empty();
  // A detached/unlaid-out view can have a requested animation without any CA
  // delegate capable of completing it. Once every installed animation ends,
  // make those deferred views statically correct and invalidate their pending
  // ids before releasing the driver-level completion.
  for (const ViewKey key : state.views) {
    [viewForKey(key) smoothClipCancelAnimationUsingTarget:YES];
  }
  state.ownership = Ownership::Interactive;
  emitCompletion(driverId, state, animationId, finished);
}

void applyPresentation(
    DriverState &state,
    Presentation presentation,
    bool recordVelocitySample = true) {
  if (!canonicalizePresentation(presentation)) return;
  state.latest = presentation;
  state.hasLatest = true;
  state.ownership = Ownership::Interactive;
  for (const ViewKey key : state.views) {
    [viewForKey(key) smoothClipApplyPresentation:presentation
                              recordVelocitySample:recordVelocitySample];
  }
}

void prepareAnimation(
    uint64_t driverId,
    DriverState &state,
    AnimationStart start,
    Presentation target) {
  // An explicit `from` is part of the new animation's start transaction. It
  // intentionally overrides a sampled native frame even when this operation
  // is replacing another native-owned animation.
  const bool acceptsInteractiveStart = start.hasInteractiveStart;
  cancelActive(driverId, state, false);
  if (acceptsInteractiveStart) {
    applyPresentation(state, start.interactiveStart);
  }
  state.latest = target;
  state.hasLatest = true;
  state.ownership = Ownership::Native;
}

// Mirrors prepareAnimation's start resolution. Must be evaluated before
// prepareAnimation overwrites state.latest with the target.
Presentation resolvedAnimationStart(
    const DriverState &state,
    const AnimationStart &start) {
  if (start.hasInteractiveStart) {
    return start.interactiveStart;
  }
  // Replacing a latched animation (e.g. open→close before the host mounted):
  // it never rendered, and state.latest is its target — start from where the
  // clip actually is, the latch's own start.
  if (state.animation.has_value() && !state.animation->started) {
    return state.animation->start;
  }
  return state.animation.has_value()
      ? canonicalVisiblePresentation(state)
      : state.latest;
}

// Installs the remaining part of the active animation on a view that joins
// mid-flight, starting from `visible`. Shared by registerView (mount during
// animation) and joinActiveAnimation (first layout after such a mount).
void dispatchActiveAnimationJoin(
    DriverState &state,
    SmoothClipView *view,
    ViewKey key,
    const Presentation &visible,
    SmoothClipView *reference = nil,
    CFTimeInterval sharedBeginTime = 0) {
  auto &active = *state.animation;
  const double elapsedMs = sharedBeginTime > 0
      ? 0
      : (CACurrentMediaTime() - active.startedAt) * 1000.0;
  const double remainingMs = MAX(0, active.durationMs - elapsedMs);
  BOOL installed = NO;
  if (active.kind == AnimationKind::Timing) {
    const double progress = active.durationMs <= 0
        ? 1
        : MIN(1, MAX(0, elapsedMs / active.durationMs));
    TimingAnimation timing = timingRemainder(active.timing, progress).animation;
    installed = [view smoothClipAnimateTiming:state.latest
                                    animation:timing
                                  animationId:active.animationId
                              sharedBeginTime:sharedBeginTime];
  } else if (active.kind == AnimationKind::Spring) {
    SpringAnimation spring = active.spring;
    if (reference != nil) {
      // A late host must join the spring's CURRENT physical state. Reusing the
      // original launch velocity (or resolving `inherit` from the joining
      // host's unrelated samples) creates a different spring at the seam.
      spring.inheritVelocity = false;
      spring.initialVelocity =
          [reference smoothClipSpringContinuationVelocity];
    }
    installed = [view smoothClipAnimateSpring:state.latest
                                    animation:spring
                                  animationId:active.animationId
                              sharedBeginTime:sharedBeginTime];
  } else {
    const double progress = active.durationMs <= 0
        ? 1
        : MIN(1, MAX(0, elapsedMs / active.durationMs));
    std::vector<Keyframe> remaining;
    remaining.push_back({0, visible});
    for (const Keyframe &frame : active.keyframes) {
      if (frame.offset <= progress) continue;
      const double offset = (frame.offset - progress) / (1 - progress);
      remaining.push_back({offset, frame.presentation});
    }
    if (remaining.size() == 1) remaining.push_back({1, state.latest});
    installed = [view smoothClipAnimateKeyframes:state.latest
                                      keyframes:remaining
                                     durationMs:remainingMs
                                    animationId:active.animationId
                                sharedBeginTime:sharedBeginTime];
  }
  if (installed) {
    active.participants.insert(key);
    active.suspendedParticipants.erase(key);
  }
}

// An animation may only start once a registered view can actually produce a
// visible frame. A CA animation committed while its layer tree is detached
// from the render tree (a transparentModal subtree before UIKit presents its
// view controller) is removed at the attach commit with finished=NO, which
// snaps the layer to its model values — the animation's target.
bool anyDisplayableView(const DriverState &state) {
  for (const ViewKey key : state.views) {
    if ([viewForKey(key) smoothClipCanDisplay]) return true;
  }
  return false;
}

void relatchActiveAnimation(
    uint64_t driverId,
    DriverState &state,
    SmoothClipView *preferred = nil) {
  if (!state.animation.has_value() || !state.animation->started) return;
  auto &active = *state.animation;
  double springVelocity = 0;
  if (active.kind == AnimationKind::Spring) {
    SmoothClipView *source = preferred;
    if (source == nil ||
        active.participants.count(keyForView(source)) == 0) {
      source = active.participants.empty()
          ? nil
          : viewForKey(*active.participants.begin());
    }
    if (source != nil) {
      springVelocity = [source smoothClipSpringContinuationVelocity];
    }
  }
  const Presentation frozen = canonicalFrozenPresentation(state, preferred);
  // Captured before the migration below: only hosts that were ALREADY
  // suspended are unresolved. The active participants being frozen right now
  // rendered every frame up to this instant.
  const bool hadUnresolvedSuspended = !active.suspendedParticipants.empty();
  active.suspendedParticipants.insert(
      active.participants.begin(), active.participants.end());
  active.participants.clear();

  const double elapsedMs = MAX(
      0, (CACurrentMediaTime() - active.startedAt) * 1000.0);
  const double progress = active.durationMs <= 0
      ? 1
      : MIN(1, MAX(0, elapsedMs / active.durationMs));
  if (active.kind == AnimationKind::Timing) {
    active.timing = timingRemainder(active.timing, progress).animation;
    active.durationMs = active.timing.durationMs;
  } else if (active.kind == AnimationKind::Keyframes) {
    const KeyframeContinuation continuation = keyframeContinuation(
        active.keyframes,
        frozen,
        state.latest,
        active.durationMs,
        progress);
    active.keyframes = continuation.frames;
    active.durationMs = continuation.durationMs;
  } else {
    active.spring.inheritVelocity = false;
    active.spring.initialVelocity = springVelocity;
  }

  if (state.destroyed ||
      (active.kind != AnimationKind::Spring && active.durationMs <= 0)) {
    // A residual trimmed to zero means the curve fully elapsed while a host
    // displayed every frame — only the asynchronous didStop was outstanding
    // when this freeze arrived. Report that run honestly instead of stamping
    // the freeze-path false; hosts that were suspended before the freeze are
    // unresolved and still poison it.
    const bool ranToEnd = !state.destroyed && progress >= 1 &&
        active.finished && !hadUnresolvedSuspended;
    // Deferred peers hold pending installs for this id; invalidate them and
    // finalize statically at the target, exactly as the didStop completion
    // path does. Frozen participants already have no animation to cancel.
    for (const ViewKey key : state.views) {
      [viewForKey(key) smoothClipCancelAnimationUsingTarget:YES];
    }
    state.ownership = Ownership::Interactive;
    emitCompletion(driverId, state, active.animationId, ranToEnd);
    return;
  }
  active.start = frozen;
  active.started = false;
}

// Starts a latched animation: rebases the clock so no progress was burned
// while no view could display, then dispatches the join to every registered
// view. Views that still cannot display defer their install per-view and
// resume via a later positive displayability update.
void startLatchedAnimation(DriverState &state) {
  if (state.animation->groupId != 0) {
    tryStartGroup(state.animation->groupId);
    return;
  }
  state.animation->startedAt = CACurrentMediaTime();
  state.animation->started = true;
  // Participants describe live CA delegates, not registered views. Anything
  // left from the frozen run can only produce a stale callback for that run.
  state.animation->participants.clear();
  const Presentation start = state.animation->start;
  for (const ViewKey key : state.views) {
    SmoothClipView *participant = viewForKey(key);
    [participant smoothClipApplyPresentation:start recordVelocitySample:NO];
    dispatchActiveAnimationJoin(state, participant, key, start);
  }
}

void tryStartGroup(int32_t groupId) {
  auto groupIterator = groupRegistry().find(groupId);
  if (groupIterator == groupRegistry().end() ||
      groupIterator->second.mutating) {
    return;
  }
  const std::vector<uint64_t> driverIds = groupIterator->second.driverIds;
  for (const uint64_t driverId : driverIds) {
    const auto stateIterator = registry().find(driverId);
    if (stateIterator == registry().end() ||
        !stateIterator->second.animation.has_value() ||
        stateIterator->second.animation->groupId != groupId ||
        !driverReady(stateIterator->second)) {
      return;
    }
  }

  const CFTimeInterval sharedBeginTime = CACurrentMediaTime();
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  for (const uint64_t driverId : driverIds) {
    DriverState &state = registry().find(driverId)->second;
    ActiveAnimation &active = *state.animation;
    active.startedAt = sharedBeginTime;
    active.started = true;
    active.participants.clear();
    const Presentation start = active.start;
    for (const ViewKey key : state.views) {
      SmoothClipView *participant = viewForKey(key);
      [participant smoothClipApplyPresentation:start recordVelocitySample:NO];
      dispatchActiveAnimationJoin(
          state,
          participant,
          key,
          start,
          nil,
          sharedBeginTime);
    }
  }
  [CATransaction commit];
}

void suspendGroup(int32_t groupId) {
  auto groupIterator = groupRegistry().find(groupId);
  if (groupIterator == groupRegistry().end() ||
      groupIterator->second.mutating) {
    return;
  }
  if (groupIterator->second.suspensionPolicy ==
      GroupSuspensionPolicy::Finish) {
    cancelGroupInternal(
        groupId, GroupCancelBehavior::Finish, true);
    return;
  }

  groupIterator->second.mutating = true;
  const std::vector<uint64_t> driverIds = groupIterator->second.driverIds;
  for (const uint64_t driverId : driverIds) {
    auto stateIterator = registry().find(driverId);
    if (stateIterator != registry().end() &&
        stateIterator->second.animation.has_value() &&
        stateIterator->second.animation->groupId == groupId) {
      relatchActiveAnimation(driverId, stateIterator->second);
    } else {
      groupMemberCompleted(groupId, driverId, false);
    }
  }

  groupIterator = groupRegistry().find(groupId);
  if (groupIterator == groupRegistry().end()) return;
  GroupState &group = groupIterator->second;
  group.mutating = false;
  if (!group.remainingDriverIds.empty()) return;
  const uint64_t controllerId = group.controllerId;
  const bool finished = group.finished;
  const std::vector<uint64_t> completedDrivers = group.driverIds;
  groupRegistry().erase(groupIterator);
  emitGroupCompletion(controllerId, groupId, finished, completedDrivers);
}

} // namespace

bool applicationIsActive() {
  return applicationActiveState();
}

void applicationWillResignActive() {
  NSCAssert(NSThread.isMainThread, @"SmoothClip registry is main-thread only");
  if (!applicationActiveState()) return;
  applicationActiveState() = false;
  std::vector<int32_t> groupIds;
  groupIds.reserve(groupRegistry().size());
  for (const auto &[groupId, group] : groupRegistry()) {
    (void)group;
    groupIds.push_back(groupId);
  }
  for (const int32_t groupId : groupIds) {
    suspendGroup(groupId);
  }
  for (auto &[driverId, state] : registry()) {
    if (!state.animation.has_value() || state.animation->groupId == 0) {
      relatchActiveAnimation(driverId, state);
    }
  }
}

void applicationDidBecomeActive() {
  NSCAssert(NSThread.isMainThread, @"SmoothClip registry is main-thread only");
  if (applicationActiveState()) return;
  applicationActiveState() = true;
  std::vector<int32_t> groupIds;
  groupIds.reserve(groupRegistry().size());
  for (const auto &[groupId, group] : groupRegistry()) {
    (void)group;
    groupIds.push_back(groupId);
  }
  for (const int32_t groupId : groupIds) {
    tryStartGroup(groupId);
  }
  for (auto &[driverId, state] : registry()) {
    (void)driverId;
    if (state.animation.has_value() && !state.animation->started &&
        state.animation->groupId == 0 && anyDisplayableView(state)) {
      startLatchedAnimation(state);
    }
  }
}

void setCompletionCallback(
    const void *owner,
    CompletionCallback callback) {
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

void registerView(
    uint64_t driverId,
    SmoothClipView *view,
    Presentation initialPresentation) {
  NSCAssert(NSThread.isMainThread, @"SmoothClip registry is main-thread only");
  if (!canonicalizePresentation(initialPresentation)) return;
  auto &state = registry()[driverId];
  state.destroyed = false;
  // Seed canonical geometry from the mounting view's initial props BEFORE
  // sampling `visible`; otherwise the first registration captures the default
  // empty {0,0,0,0} rect, seeding the view (and the presentation layer the
  // opening timing animation samples as its "from") to the top-left instead of
  // the real origin rectangle.
  if (!state.hasLatest) {
    state.latest = initialPresentation;
    state.hasLatest = true;
  }
  const bool hasAnimation = state.animation.has_value();
  const bool hasLatch = hasAnimation && !state.animation->started;
  // A latch may only start once this view can produce a visible frame; a
  // registration from a detached subtree (transparentModal before its view
  // controller is presented) keeps the latch held; the positive
  // displayability update starts it inside the attach commit.
  const bool startsLatch = hasLatch && [view smoothClipCanDisplay];
  const bool shouldReplay =
      hasAnimation && state.animation->started && !state.views.empty();
  Presentation visible = state.latest;
  SmoothClipView *reference = nil;
  if (shouldReplay) {
    // A registered peer that never laid out reports zero geometry; joining
    // from it would visibly collapse the clip. Prefer the first laid-out
    // peer and fall back to the animation's start.
    for (const ViewKey candidate : state.animation->participants) {
      SmoothClipView *candidateView = viewForKey(candidate);
      if ([candidateView smoothClipIsJoinable]) {
        reference = candidateView;
        break;
      }
    }
    visible = reference != nil
        ? [reference smoothClipCurrentPresentation]
        : state.animation->start;
  } else if (hasLatch) {
    // state.latest already holds the latch's TARGET; applying it here is
    // exactly the jump this path exists to avoid.
    visible = state.animation->start;
  }
  const ViewKey key = keyForView(view);
  if (std::find(state.views.begin(), state.views.end(), key) ==
      state.views.end()) {
    state.views.push_back(key);
  }
  [view smoothClipApplyPresentation:visible recordVelocitySample:NO];
  if (startsLatch) {
    // Rebase the join clock and dispatch to every registered view. Only views
    // that actually install their CA groups become completion participants.
    startLatchedAnimation(state);
    return;
  }
  if (!shouldReplay) return;
  dispatchActiveAnimationJoin(state, view, key, visible, reference);
}

void viewDisplayabilityChanged(uint64_t driverId, SmoothClipView *view) {
  NSCAssert(NSThread.isMainThread, @"SmoothClip registry is main-thread only");
  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return;
  auto &state = iterator->second;
  if (!state.animation.has_value()) return;
  const ViewKey key = keyForView(view);
  if (std::find(state.views.begin(), state.views.end(), key) ==
      state.views.end()) {
    return;
  }
  const int32_t groupId = state.animation->groupId;
  if (groupId != 0) {
    if (![view smoothClipCanDisplay]) {
      if (!state.animation->started) {
        if (!driverReady(state)) suspendGroup(groupId);
        return;
      }
      if (state.animation->participants.count(key) == 0) {
        return;
      }
      if (!driverReady(state)) {
        suspendGroup(groupId);
        return;
      }
      [view smoothClipFreezePresentation];
      if (state.animation.has_value() &&
          state.animation->groupId == groupId) {
        state.animation->participants.erase(key);
        state.animation->suspendedParticipants.insert(key);
      }
      return;
    }
    if (!state.animation->started) {
      tryStartGroup(groupId);
      return;
    }
    if ([view smoothClipHasPendingInstall] ||
        state.animation->suspendedParticipants.count(key) > 0) {
      joinActiveAnimation(driverId, view);
    }
    return;
  }
  if (![view smoothClipCanDisplay]) {
    if (!state.animation->started) return;
    if (state.animation->participants.count(key) == 0) return;
    if (!anyDisplayableView(state)) {
      relatchActiveAnimation(driverId, state, view);
      return;
    }
    [view smoothClipFreezePresentation];
    state.animation->participants.erase(key);
    state.animation->suspendedParticipants.insert(key);
    return;
  }
  if (!state.animation->started) {
    startLatchedAnimation(state);
    return;
  }
  // A deferred or suspended host joins from the registry's rebased remainder.
  if ([view smoothClipHasPendingInstall] ||
      state.animation->suspendedParticipants.count(key) > 0) {
    joinActiveAnimation(driverId, view);
  }
}

bool joinActiveAnimation(uint64_t driverId, SmoothClipView *view) {
  NSCAssert(NSThread.isMainThread, @"SmoothClip registry is main-thread only");
  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) {
    return false;
  }
  auto &state = iterator->second;
  if (!state.animation.has_value() || state.views.empty()) {
    return false;
  }
  const ViewKey key = keyForView(view);
  if (std::find(state.views.begin(), state.views.end(), key) ==
      state.views.end()) {
    return false;
  }
  // A pending install used to imply the animation was dispatched, which
  // implied started. Re-latching on displayability broke that: when the last
  // displayable host leaves, a peer that deferred its install keeps
  // `_pendingAnimationInstall` while the animation goes back to un-started, and
  // its first layout lands here. Start the latch — returning false would make
  // the caller clear `_activeAnimationId` and apply the requested geometry,
  // snapping this view straight to the target. A *join* must still never
  // compute elapsed time against an un-rebased latch clock, so this returns
  // instead of falling through.
  if (!state.animation->started) {
    if (![view smoothClipCanDisplay]) return false;
    if (state.animation->groupId != 0) {
      const int32_t groupId = state.animation->groupId;
      tryStartGroup(groupId);
      return state.animation.has_value() && state.animation->started;
    }
    startLatchedAnimation(state);
    return true;
  }
  // Join from a laid-out peer's live presentation, exactly as a view that had
  // registered at this moment would. When the joining view is the only
  // registered host, its own layer never received geometry (the install was
  // deferred for lack of layout), so fall back to the animation's start.
  SmoothClipView *reference = nil;
  for (const ViewKey candidate : state.animation->participants) {
    if (candidate != key && [viewForKey(candidate) smoothClipIsJoinable]) {
      reference = viewForKey(candidate);
      break;
    }
  }
  const Presentation visible = reference != nil
      ? [reference smoothClipCurrentPresentation]
      : state.animation->start;
  [view smoothClipApplyPresentation:visible recordVelocitySample:NO];
  dispatchActiveAnimationJoin(state, view, key, visible, reference);
  return true;
}

void unregisterView(uint64_t driverId, SmoothClipView *view) {
  NSCAssert(NSThread.isMainThread, @"SmoothClip registry is main-thread only");
  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return;

  auto &state = iterator->second;
  const ViewKey key = keyForView(view);
  const int32_t groupId = state.animation.has_value()
      ? state.animation->groupId
      : 0;
  if (groupId != 0) {
    const bool installed =
        state.animation->participants.count(key) > 0 ||
        state.animation->suspendedParticipants.count(key) > 0;
    bool otherDisplayable = false;
    for (const ViewKey candidate : state.views) {
      if (candidate != key && [viewForKey(candidate) smoothClipCanDisplay]) {
        otherDisplayable = true;
        break;
      }
    }
    if (!otherDisplayable) {
      suspendGroup(groupId);
    } else if (state.animation.has_value() && state.animation->started &&
               state.animation->participants.count(key) > 0) {
        [view smoothClipFreezePresentation];
    }
    state.views.erase(
        std::remove(state.views.begin(), state.views.end(), key),
        state.views.end());
    if (state.animation.has_value() &&
        state.animation->groupId == groupId) {
      state.animation->participants.erase(key);
      state.animation->suspendedParticipants.erase(key);
      // A duplicate rendering host may leave without poisoning the immutable
      // driver participant. If the driver lost its only host, the group's
      // suspension policy above owns the result.
      if (installed && otherDisplayable &&
          state.animation->participants.empty()) {
        suspendGroup(groupId);
      }
    }
    if (state.destroyed && state.views.empty()) {
      registry().erase(iterator);
    }
    return;
  }
  bool installed = false;
  if (state.animation.has_value()) {
    installed = state.animation->participants.count(key) > 0 ||
        state.animation->suspendedParticipants.count(key) > 0;
    if (state.animation->started &&
        state.animation->participants.count(key) > 0) {
      bool otherDisplayable = false;
      for (const ViewKey candidate : state.views) {
        if (candidate != key && [viewForKey(candidate) smoothClipCanDisplay]) {
          otherDisplayable = true;
          break;
        }
      }
      if (!otherDisplayable) {
        relatchActiveAnimation(driverId, state, view);
      }
    }
  }

  state.views.erase(
      std::remove(state.views.begin(), state.views.end(), key),
      state.views.end());
  if (state.animation.has_value()) {
    state.animation->participants.erase(key);
    state.animation->suspendedParticipants.erase(key);
    if (installed) state.animation->finished = false;
    if (state.animation->started && state.animation->participants.empty()) {
      finishIfNoInstalledParticipants(driverId, state);
    }
  }
  if (state.destroyed && state.views.empty()) {
    registry().erase(iterator);
  }
}

void setPresentation(
    uint64_t driverId,
    Presentation presentation,
    bool takeOwnership,
    bool overridePendingAnimation,
    bool recordVelocity) {
  if (!canonicalizePresentation(presentation)) return;
  // CALayer writes require the main thread (not main-queue drain context).
  if (!NSThread.isMainThread) {
    // Never block an off-main caller: a synchronous hop can deadlock against
    // the worklets UI-runtime mutex (runOnUISync executes on the calling
    // thread while holding it, and the main thread routinely waits for the
    // same mutex when draining scheduled worklets).
    RCTExecuteOnMainQueue(^{
      setPresentation(
          driverId, presentation, takeOwnership, overridePendingAnimation,
          recordVelocity);
    });
    return;
  }
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
#if defined(SMOOTH_CLIP_ENABLE_SIGNPOSTS) && SMOOTH_CLIP_ENABLE_SIGNPOSTS
  const bool signpostsEnabled = os_signpost_enabled(signpostLog());
  os_signpost_id_t identifier = OS_SIGNPOST_ID_NULL;
  if (signpostsEnabled) {
    identifier = os_signpost_id_generate(signpostLog());
    os_signpost_interval_begin(
        signpostLog(), identifier, "lookup-fanout", "driver=%llu", driverId);
  }
#endif
  auto &state = iterator->second;
  if (!takeOwnership && state.ownership != Ownership::Interactive) {
#if defined(SMOOTH_CLIP_ENABLE_SIGNPOSTS) && SMOOTH_CLIP_ENABLE_SIGNPOSTS
    if (signpostsEnabled) {
      os_signpost_interval_end(
          signpostLog(), identifier, "lookup-fanout", "ignored=native-owner");
    }
#endif
    return;
  }
  if (takeOwnership) {
    state.destroyed = false;
    // Passive seeds and public setters must not displace newer pending intent.
    // The fused animation.from write is authoritative and opts in explicitly.
    if (state.animation.has_value() && !state.animation->started &&
        !overridePendingAnimation) {
#if defined(SMOOTH_CLIP_ENABLE_SIGNPOSTS) && SMOOTH_CLIP_ENABLE_SIGNPOSTS
      if (signpostsEnabled) {
        os_signpost_interval_end(
            signpostLog(), identifier, "lookup-fanout", "ignored=held-latch");
      }
#endif
      return;
    }
    cancelActive(driverId, state, false);
  }
  applyPresentation(state, presentation, recordVelocity);
#if defined(SMOOTH_CLIP_ENABLE_SIGNPOSTS) && SMOOTH_CLIP_ENABLE_SIGNPOSTS
  if (signpostsEnabled) {
    os_signpost_interval_end(
        signpostLog(), identifier, "lookup-fanout", "views=%lu",
        static_cast<unsigned long>(state.views.size()));
  }
#endif
}

void setScalars(
    uint64_t driverId,
    Geometry geometry,
    double contentTranslateX,
    double contentTranslateY,
    double contentScale,
    bool overridePendingAnimation,
    bool recordVelocity) {
  Presentation presentation = snapshotCurrent(driverId);
  if (!isFinitePresentation(presentation)) return;
  presentation.clip = geometry;
  presentation.contentTranslateX = contentTranslateX;
  presentation.contentTranslateY = contentTranslateY;
  presentation.contentScale = contentScale;
  setPresentation(
      driverId, presentation, true, overridePendingAnimation, recordVelocity);
}

Presentation beginInteraction(uint64_t driverId) {
  if (!NSThread.isMainThread) {
    // See setPresentation: blocking off-main risks a deadlock, so the call
    // fails defined and the JS side keeps its current value.
    return unavailablePresentation();
  }  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return unavailablePresentation();
  auto &state = iterator->second;
  state.destroyed = false;
  if (!state.animation.has_value()) {
    state.ownership = Ownership::Interactive;
    return state.latest;
  }

  if (state.animation->groupId != 0) {
    const int32_t groupId = state.animation->groupId;
    cancelGroupInternal(
        groupId, GroupCancelBehavior::Freeze, false);
    const auto current = registry().find(driverId);
    return current == registry().end()
        ? unavailablePresentation()
        : current->second.latest;
  }

  const int32_t animationId = state.animation->animationId;
  const Presentation canonical = canonicalFrozenPresentation(state);
  state.latest = canonical;
  state.hasLatest = true;
  state.ownership = Ownership::Interactive;
  emitCompletion(driverId, state, animationId, false);
  return canonical;
}

Presentation snapshotCurrent(uint64_t driverId) {
  if (!NSThread.isMainThread) return unavailablePresentation();
  const auto iterator = registry().find(driverId);
  if (iterator == registry().end() || iterator->second.destroyed) {
    return unavailablePresentation();
  }
  return canonicalVisiblePresentation(iterator->second);
}

std::vector<DriverSnapshot> snapshotGroup(
    const std::vector<uint64_t> &driverIds) {
  if (!NSThread.isMainThread) return {};
  std::vector<DriverSnapshot> snapshots;
  snapshots.reserve(driverIds.size());
  for (const uint64_t driverId : driverIds) {
    snapshots.push_back(snapshotForDriver(driverId));
  }
  return snapshots;
}

std::vector<DriverSnapshot> beginGroupInteraction(
    const std::vector<uint64_t> &driverIds) {
  if (!NSThread.isMainThread) return {};
  std::unordered_set<uint64_t> unique;
  for (const uint64_t driverId : driverIds) {
    const auto iterator = registry().find(driverId);
    if (driverId == 0 || !unique.insert(driverId).second ||
        iterator == registry().end() || iterator->second.destroyed) {
      std::vector<DriverSnapshot> unavailable;
      unavailable.reserve(driverIds.size());
      for (const uint64_t requested : driverIds) {
        unavailable.push_back(
            {requested, unavailablePresentation(), false});
      }
      return unavailable;
    }
  }

  std::unordered_set<int32_t> cancelledGroups;
  for (const uint64_t driverId : driverIds) {
    DriverState &state = registry().find(driverId)->second;
    if (!state.animation.has_value()) continue;
    const int32_t groupId = state.animation->groupId;
    if (groupId != 0) {
      if (cancelledGroups.insert(groupId).second) {
        cancelGroupInternal(
            groupId, GroupCancelBehavior::Freeze, false);
      }
      continue;
    }
    const int32_t animationId = state.animation->animationId;
    const Presentation frozen = canonicalFrozenPresentation(state);
    state.latest = frozen;
    state.hasLatest = true;
    state.ownership = Ownership::Interactive;
    emitCompletion(driverId, state, animationId, false);
  }

  std::vector<DriverSnapshot> snapshots;
  snapshots.reserve(driverIds.size());
  for (const uint64_t driverId : driverIds) {
    DriverState &state = registry().find(driverId)->second;
    state.destroyed = false;
    state.ownership = Ownership::Interactive;
    snapshots.push_back(
        {driverId, state.latest, driverReady(state)});
  }
  return snapshots;
}

bool setPresentationBatch(const std::vector<BatchEntry> &entries) {
  if (!NSThread.isMainThread) return false;
  std::vector<BatchEntry> canonicalEntries = entries;
  for (BatchEntry &entry : canonicalEntries) {
    if (!canonicalizePresentation(entry.presentation)) return false;
  }
  std::unordered_set<uint64_t> unique;
  for (const BatchEntry &entry : canonicalEntries) {
    const auto iterator = registry().find(entry.driverId);
    if (entry.driverId == 0 || !unique.insert(entry.driverId).second ||
        iterator == registry().end() || iterator->second.destroyed ||
        !isFinitePresentation(entry.presentation)) {
      return false;
    }
  }

  std::unordered_set<int32_t> cancelledGroups;
  for (const BatchEntry &entry : canonicalEntries) {
    DriverState &state = registry().find(entry.driverId)->second;
    if (!state.animation.has_value()) continue;
    const int32_t groupId = state.animation->groupId;
    if (groupId != 0) {
      if (cancelledGroups.insert(groupId).second) {
        cancelGroupInternal(
            groupId, GroupCancelBehavior::Freeze, false);
      }
      continue;
    }
    const int32_t animationId = state.animation->animationId;
    const Presentation frozen = canonicalFrozenPresentation(state);
    state.latest = frozen;
    state.hasLatest = true;
    state.ownership = Ownership::Interactive;
    emitCompletion(entry.driverId, state, animationId, false);
  }

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  for (const BatchEntry &entry : canonicalEntries) {
    applyPresentation(
        registry().find(entry.driverId)->second, entry.presentation, true);
  }
  [CATransaction commit];
  return true;
}

namespace {

bool preflightGroupEntries(
    std::vector<GroupMotionEntry> &entries,
    AnimationKind kind,
    const TimingAnimation &timing,
    const SpringAnimation &spring,
    double durationMs,
    int32_t reduceMotion,
    bool &reduced,
    std::vector<Presentation> &resolvedStarts) {
  if (entries.empty()) return false;
  for (GroupMotionEntry &entry : entries) {
    if ((entry.hasFrom && !canonicalizePresentation(entry.from)) ||
        !canonicalizePresentation(entry.target) ||
        !canonicalizeKeyframes(entry.keyframes)) {
      return false;
    }
  }
  if (kind == AnimationKind::Timing &&
      !isValidTiming(timing)) {
    return false;
  }
  if (kind == AnimationKind::Spring &&
      !isValidSpring(spring)) {
    return false;
  }
  if (kind == AnimationKind::Keyframes &&
      (!std::isfinite(durationMs) || durationMs < 0 ||
       !isValidReduceMotionCode(reduceMotion))) {
    return false;
  }
  reduced = shouldReduceMotion(reduceMotion) ||
      (kind != AnimationKind::Spring && durationMs <= 0);
  std::unordered_set<uint64_t> unique;
  resolvedStarts.clear();
  resolvedStarts.reserve(entries.size());
  for (const GroupMotionEntry &entry : entries) {
    if (entry.driverId == 0 || !unique.insert(entry.driverId).second) {
      return false;
    }
    const auto iterator = registry().find(entry.driverId);
    if ((iterator == registry().end() || iterator->second.destroyed ||
         !iterator->second.hasLatest) && !entry.hasFrom) {
      return false;
    }
    const Presentation resolvedStart = entry.hasFrom
        ? entry.from
        : canonicalVisiblePresentation(iterator->second);
    if (!isFinitePresentation(resolvedStart) ||
        !isFinitePresentation(entry.target) ||
        resolvedStart.clip.curve != entry.target.clip.curve) {
      return false;
    }
    if (kind == AnimationKind::Spring &&
        !springScaleIsProvablyPositive(
            resolvedStart, entry.target, spring)) {
      return false;
    }
    if (kind == AnimationKind::Keyframes) {
      if (!isValidKeyframes(
              entry.keyframes,
              resolvedStart,
              entry.target,
              entry.hasFrom)) {
        return false;
      }
    } else if (!entry.keyframes.empty()) {
      return false;
    }
    resolvedStarts.push_back(resolvedStart);
  }
  return true;
}

void freezeReplacedAnimations(
    const std::vector<GroupMotionEntry> &entries) {
  std::unordered_set<int32_t> cancelledGroups;
  for (const GroupMotionEntry &entry : entries) {
    auto iterator = registry().find(entry.driverId);
    if (iterator == registry().end() ||
        !iterator->second.animation.has_value()) {
      continue;
    }
    DriverState &state = iterator->second;
    const int32_t oldGroupId = state.animation->groupId;
    if (oldGroupId != 0) {
      if (cancelledGroups.insert(oldGroupId).second) {
        cancelGroupInternal(
            oldGroupId, GroupCancelBehavior::Freeze, false);
      }
      continue;
    }
    const int32_t animationId = state.animation->animationId;
    const Presentation frozen = canonicalFrozenPresentation(state);
    state.latest = frozen;
    state.hasLatest = true;
    state.ownership = Ownership::Interactive;
    emitCompletion(entry.driverId, state, animationId, false);
  }
}

int32_t createGroupAnimation(
    uint64_t controllerId,
    std::vector<GroupMotionEntry> entries,
    AnimationKind kind,
    TimingAnimation timing,
    SpringAnimation spring,
    double durationMs,
    int32_t reduceMotion,
    GroupSuspensionPolicy suspensionPolicy) {
  std::vector<Presentation> resolvedStarts;
  bool reduced = false;
  if (!NSThread.isMainThread || controllerId == 0 ||
      !preflightGroupEntries(
          entries,
          kind,
          timing,
          spring,
          durationMs,
          reduceMotion,
          reduced,
          resolvedStarts)) {
    return 0;
  }

  // No state changes occur before every entry is known to be viable. Once
  // preflight succeeds, replacement freezes each overlapping group at most
  // once and reports its stale completion before installing the new epoch.
  freezeReplacedAnimations(entries);
  const int32_t groupId = allocateAnimationId();
  std::vector<uint64_t> driverIds;
  driverIds.reserve(entries.size());
  for (const GroupMotionEntry &entry : entries) {
    driverIds.push_back(entry.driverId);
  }

  if (reduced) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (const GroupMotionEntry &entry : entries) {
      auto iterator = registry().find(entry.driverId);
      if (iterator == registry().end()) {
        iterator = registry().try_emplace(entry.driverId).first;
      }
      DriverState &state = iterator->second;
      state.destroyed = false;
      applyPresentation(state, entry.target, false);
    }
    [CATransaction commit];
    emitGroupCompletion(controllerId, groupId, true, driverIds);
    return groupId;
  }

  GroupState group{
      controllerId,
      groupId,
      driverIds,
      std::unordered_set<uint64_t>(driverIds.begin(), driverIds.end()),
      suspensionPolicy,
  };
  groupRegistry().emplace(groupId, std::move(group));

  for (std::size_t entryIndex = 0; entryIndex < entries.size(); entryIndex += 1) {
    GroupMotionEntry &entry = entries[entryIndex];
    auto iterator = registry().find(entry.driverId);
    if (iterator == registry().end()) {
      iterator = registry().try_emplace(entry.driverId).first;
    }
    DriverState &state = iterator->second;
    state.destroyed = false;
    if (entry.hasFrom) {
      applyPresentation(state, entry.from, true);
    }
    const Presentation start = resolvedStarts[entryIndex];
    if (kind == AnimationKind::Keyframes && !entry.keyframes.empty()) {
      // An omitted `from` is a native-to-native retarget: sample the visible
      // presentation before replacement and substitute that exact value as
      // frame zero. Explicit endpoints were already validated and are never
      // silently corrected by native.
      if (!entry.hasFrom) entry.keyframes.front().presentation = start;
    }
    state.latest = entry.target;
    state.hasLatest = true;
    state.ownership = Ownership::Native;

    ActiveAnimation active{groupId};
    active.groupId = groupId;
    active.kind = kind;
    active.start = start;
    active.timing = timing;
    active.spring = spring;
    active.keyframes = std::move(entry.keyframes);
    active.durationMs = durationMs;
    active.started = false;
    state.animation = std::move(active);
  }
  tryStartGroup(groupId);
  return groupId;
}

} // namespace

int32_t animateTimingGroup(
    uint64_t controllerId,
    std::vector<GroupMotionEntry> entries,
    TimingAnimation animation,
    GroupSuspensionPolicy suspensionPolicy,
    double startedAtHintS) {
  (void)startedAtHintS;
  return createGroupAnimation(
      controllerId,
      std::move(entries),
      AnimationKind::Timing,
      animation,
      {},
      animation.durationMs,
      animation.reduceMotion,
      suspensionPolicy);
}

int32_t animateSpringGroup(
    uint64_t controllerId,
    std::vector<GroupMotionEntry> entries,
    SpringAnimation animation,
    GroupSuspensionPolicy suspensionPolicy,
    double startedAtHintS) {
  (void)startedAtHintS;
  return createGroupAnimation(
      controllerId,
      std::move(entries),
      AnimationKind::Spring,
      {},
      animation,
      0,
      animation.reduceMotion,
      suspensionPolicy);
}

int32_t animateKeyframesGroup(
    uint64_t controllerId,
    std::vector<GroupMotionEntry> entries,
    double durationMs,
    int32_t reduceMotion,
    GroupSuspensionPolicy suspensionPolicy,
    double startedAtHintS) {
  (void)startedAtHintS;
  return createGroupAnimation(
      controllerId,
      std::move(entries),
      AnimationKind::Keyframes,
      {},
      {},
      durationMs,
      reduceMotion,
      suspensionPolicy);
}

std::vector<DriverSnapshot> cancelAnimationGroup(
    int32_t groupId,
    GroupCancelBehavior behavior) {
  if (!NSThread.isMainThread || groupId <= 0) return {};
  return cancelGroupInternal(
      groupId,
      behavior,
      behavior == GroupCancelBehavior::Finish);
}

int32_t animateTiming(
    uint64_t driverId,
    AnimationStart start,
    Presentation presentation,
    TimingAnimation animation) {
  if (!NSThread.isMainThread) {
    // See setPresentation: blocking off-main risks a deadlock. 0 is the
    // documented rejection sentinel.
    return 0;
  }
  if (!canonicalizePresentation(presentation) ||
      (start.hasInteractiveStart &&
       !canonicalizePresentation(start.interactiveStart))) {
    return 0;
  }
  const bool validAnimation = isValidTiming(animation);
  if (driverId == 0 || !isFinitePresentation(presentation) ||
      !validAnimation) {
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
    preflightStart = resolvedAnimationStart(iterator->second, start);
  }
  if (!isFinitePresentation(preflightStart) ||
      preflightStart.clip.curve != presentation.clip.curve) {
    return 0;
  }
  const bool reduced = shouldReduceMotion(animation.reduceMotion) ||
      animation.durationMs <= 0;
  if (iterator == registry().end()) {
    iterator = registry().try_emplace(driverId).first;
    iterator->second.latest = start.interactiveStart;
    iterator->second.hasLatest = true;
  }
  auto &state = iterator->second;
  state.destroyed = false;
  const int32_t animationId = allocateAnimationId();
  const Presentation resolvedStart = preflightStart;
  prepareAnimation(driverId, state, start, presentation);

  if (reduced) {
    applyPresentation(state, presentation, false);
    emitCompletion(driverId, state, animationId, true);
    return animationId;
  }

  ActiveAnimation active{animationId};
  active.kind = AnimationKind::Timing;
  active.start = resolvedStart;
  active.timing = animation;
  active.durationMs = animation.durationMs;
  active.startedAt = CACurrentMediaTime();
  active.started = anyDisplayableView(state);
  state.animation = std::move(active);
  if (!state.animation->started) {
    // Latch: no host view can display yet (animateTo raced the mount, or the
    // host sits in a detached subtree awaiting presentation). Ownership stays
    // Native — the pending animation owns rendering intent — and the first
    // displayable registration/attach rebases startedAt and starts it. The
    // non-zero id is still returned synchronously so the JS side does not
    // treat this as rejection.
    return animationId;
  }
#if defined(SMOOTH_CLIP_ENABLE_SIGNPOSTS) && SMOOTH_CLIP_ENABLE_SIGNPOSTS
  os_signpost_event_emit(
      signpostLog(), OS_SIGNPOST_ID_EXCLUSIVE, "transition-setup",
      "driver=%llu animation=%d views=%lu type=timing",
      driverId, animationId,
      static_cast<unsigned long>(state.views.size()));
#endif
  for (const ViewKey key : state.views) {
    if ([viewForKey(key) smoothClipAnimateTiming:presentation
                                      animation:animation
                                    animationId:animationId]) {
      state.animation->participants.insert(key);
    }
  }
  return animationId;
}

int32_t animateSpring(
    uint64_t driverId,
    AnimationStart start,
    Presentation presentation,
    SpringAnimation animation) {
  if (!NSThread.isMainThread) {
    // See setPresentation: blocking off-main risks a deadlock.
    return 0;
  }
  if (!canonicalizePresentation(presentation) ||
      (start.hasInteractiveStart &&
       !canonicalizePresentation(start.interactiveStart))) {
    return 0;
  }
  const bool validAnimation = isValidSpring(animation);
  if (driverId == 0 || !isFinitePresentation(presentation) ||
      !validAnimation) {
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
    preflightStart = resolvedAnimationStart(iterator->second, start);
  }
  if (!isFinitePresentation(preflightStart) ||
      preflightStart.clip.curve != presentation.clip.curve ||
      !springScaleIsProvablyPositive(preflightStart, presentation, animation)) {
    return 0;
  }
  if (iterator == registry().end()) {
    iterator = registry().try_emplace(driverId).first;
    iterator->second.latest = start.interactiveStart;
    iterator->second.hasLatest = true;
  }
  auto &state = iterator->second;
  state.destroyed = false;
  const int32_t animationId = allocateAnimationId();
  const Presentation resolvedStart = preflightStart;
  prepareAnimation(driverId, state, start, presentation);

  if (shouldReduceMotion(animation.reduceMotion)) {
    applyPresentation(state, presentation, false);
    emitCompletion(driverId, state, animationId, true);
    return animationId;
  }

  ActiveAnimation active{animationId};
  active.kind = AnimationKind::Spring;
  active.start = resolvedStart;
  active.spring = animation;
  active.startedAt = CACurrentMediaTime();
  active.started = anyDisplayableView(state);
  state.animation = std::move(active);
  if (!state.animation->started) {
    // Latched until the first displayable view — see animateTiming.
    return animationId;
  }
#if defined(SMOOTH_CLIP_ENABLE_SIGNPOSTS) && SMOOTH_CLIP_ENABLE_SIGNPOSTS
  os_signpost_event_emit(
      signpostLog(), OS_SIGNPOST_ID_EXCLUSIVE, "transition-setup",
      "driver=%llu animation=%d views=%lu type=spring",
      driverId, animationId,
      static_cast<unsigned long>(state.views.size()));
#endif
  for (const ViewKey key : state.views) {
    if ([viewForKey(key) smoothClipAnimateSpring:presentation
                                      animation:animation
                                    animationId:animationId]) {
      state.animation->participants.insert(key);
    }
  }
  return animationId;
}

int32_t animateKeyframes(
    uint64_t driverId,
    AnimationStart start,
    Presentation presentation,
    double durationMs,
    std::vector<Keyframe> keyframes,
    int32_t reduceMotion) {
  if (!NSThread.isMainThread) {
    // See setPresentation: blocking off-main risks a deadlock.
    return 0;
  }
  if (!canonicalizePresentation(presentation) ||
      (start.hasInteractiveStart &&
       !canonicalizePresentation(start.interactiveStart)) ||
      !canonicalizeKeyframes(keyframes)) {
    return 0;
  }
  const bool finiteDuration = std::isfinite(durationMs);
  if (driverId == 0 || !isFinitePresentation(presentation) ||
      !finiteDuration || durationMs < 0 ||
      !isValidReduceMotionCode(reduceMotion)) {
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
    preflightStart = resolvedAnimationStart(iterator->second, start);
  }
  const bool validKeyframes = isValidKeyframes(
      keyframes, preflightStart, presentation, start.hasInteractiveStart);
  if (!isFinitePresentation(preflightStart) || !validKeyframes) {
    return 0;
  }
  const bool reduced = shouldReduceMotion(reduceMotion) || durationMs <= 0;
  if (iterator == registry().end()) {
    iterator = registry().try_emplace(driverId).first;
    iterator->second.latest = start.interactiveStart;
    iterator->second.hasLatest = true;
  }
  auto &state = iterator->second;
  state.destroyed = false;
  const int32_t animationId = allocateAnimationId();
  const Presentation resolvedStart = preflightStart;
  prepareAnimation(driverId, state, start, presentation);
  if (reduced) {
    applyPresentation(state, presentation, false);
    emitCompletion(driverId, state, animationId, true);
    return animationId;
  }

  // Frame zero is a placeholder when the caller omits `from`. Resolve it from
  // the presentation layer/native-visible state so native-to-native retargets
  // cannot jump back to a stale compiled sample. With an explicit `from`,
  // protocol validation requires the same value, so this assignment is a
  // harmless canonicalization in both cases.
  if (!start.hasInteractiveStart) {
    keyframes.front().presentation = resolvedStart;
  }

  ActiveAnimation active{animationId};
  active.kind = AnimationKind::Keyframes;
  active.start = resolvedStart;
  active.keyframes = keyframes;
  active.durationMs = durationMs;
  active.startedAt = CACurrentMediaTime();
  active.started = anyDisplayableView(state);
  state.animation = std::move(active);
  if (!state.animation->started) {
    // Latched until the first displayable view — see animateTiming.
    return animationId;
  }
  for (const ViewKey key : state.views) {
    if ([viewForKey(key) smoothClipAnimateKeyframes:presentation
                                          keyframes:keyframes
                                         durationMs:durationMs
                                        animationId:animationId]) {
      state.animation->participants.insert(key);
    }
  }
  return animationId;
}

int32_t rejectAnimation(uint64_t driverId) {
  if (!NSThread.isMainThread) {
    // See setPresentation: blocking off-main risks a deadlock.
    return 0;
  }  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return 0;
  const int32_t animationId = allocateAnimationId();
  emitStandaloneCompletion(driverId, animationId, false);
  return animationId;
}

CancelResult cancelAnimation(
    uint64_t driverId,
    int32_t animationId,
    bool useTarget) {
  if (!NSThread.isMainThread) {
    // See setPresentation: blocking off-main risks a deadlock.
    return {false, unavailablePresentation()};
  }  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) {
    return {false, {{0, 0, 0, 0, 0}, 0, 0}};
  }
  auto &state = iterator->second;
  if (!state.animation.has_value() ||
      (animationId > 0 && animationId != state.animation->animationId)) {
    return {false, state.latest};
  }
  if (state.animation->groupId != 0) {
    const int32_t groupId = state.animation->groupId;
    const std::vector<DriverSnapshot> snapshots = cancelGroupInternal(
        groupId,
        useTarget ? GroupCancelBehavior::Finish
                  : GroupCancelBehavior::Freeze,
        useTarget);
    for (const DriverSnapshot &snapshot : snapshots) {
      if (snapshot.driverId == driverId) {
        return {true, snapshot.presentation};
      }
    }
    return {false, state.latest};
  }

#if defined(SMOOTH_CLIP_ENABLE_SIGNPOSTS) && SMOOTH_CLIP_ENABLE_SIGNPOSTS
  os_signpost_event_emit(
      signpostLog(), OS_SIGNPOST_ID_EXCLUSIVE, "cancellation",
      "driver=%llu animation=%d target=%{public}d",
      driverId, state.animation->animationId, useTarget);
#endif
  if (useTarget) {
    const Presentation target = state.latest;
    // A latch never dispatched to its views, so every participant still has
    // _activeAnimationId == 0 and smoothClipCancelAnimationUsingTarget
    // early-returns without writing anything: state.latest would report the
    // target while every layer still showed the pre-animation geometry, and
    // nothing else re-applies it. Android's cancelAnimation fans the result out
    // unconditionally — match that. Read `started` before cancelActive, which
    // resets state.animation.
    //
    // Gated on the latch case so a started animation is not written twice
    // (smoothClipCancelAnimationUsingTarget already applied the target there),
    // and applied WITHOUT a velocity sample: a jump to the target is not
    // interactive motion, and the cancel-to-target path deliberately keeps it
    // out of the 'inherit' history on both platforms — Android's cancel
    // fan-out records nothing either.
    const bool wasLatched = !state.animation->started;
    cancelActive(driverId, state, true);
    if (wasLatched) {
      // state.latest already holds the target (set at animate time); only the
      // view fan-out is missing.
      for (const ViewKey key : state.views) {
        [viewForKey(key) smoothClipApplyPresentation:target
                                recordVelocitySample:NO];
      }
    }
    state.ownership = Ownership::Interactive;
    return {true, target};
  }
  return {true, beginInteraction(driverId)};
}

void destroyDriver(uint64_t driverId) {
  if (!NSThread.isMainThread) {
    // See setPresentation: never block an off-main caller.
    RCTExecuteOnMainQueue(^{
      destroyDriver(driverId);
    });
    return;
  }  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return;
  auto &state = iterator->second;
  cancelActive(driverId, state, false);
  // A destroyed driver's interaction history must not seed a revived
  // incarnation: the revival seed would otherwise pair with these samples and
  // refresh the staleness clock with motion no finger produced.
  for (const ViewKey key : state.views) {
    [viewForKey(key) smoothClipClearVelocitySamples];
  }
  if (state.views.empty()) {
    registry().erase(iterator);
  } else {
    // Views can outlive the hook briefly (StrictMode effect replay, hosts in
    // another subtree). Keep a tombstone so their registration stays intact;
    // it is erased when the last view leaves and revived by the hook's
    // authoritative take-ownership re-seed.
    state.destroyed = true;
    state.ownership = Ownership::Interactive;
  }
}

void viewAnimationDidStop(
    uint64_t driverId,
    int32_t animationId,
    SmoothClipView *view,
    bool finished) {
  NSCAssert(NSThread.isMainThread, @"SmoothClip registry is main-thread only");
  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return;
  auto &state = iterator->second;
  if (!state.animation.has_value() ||
      state.animation->animationId != animationId) return;
  // A delegate from the frozen run can still report a stop for this id after
  // the animation has been re-latched. Draining participants there could
  // complete an animation that is waiting to resume. Only a running animation
  // may be completed by its installed delegates; a latch is completed by
  // replacement, cancel or destroy.
  if (!state.animation->started) return;

  const ViewKey key = keyForView(view);
  if (state.animation->participants.erase(key) == 0) return;
  state.animation->finished = state.animation->finished && finished;
  finishIfNoInstalledParticipants(driverId, state);
}

size_t registeredViewCount(uint64_t driverId) {
  auto iterator = registry().find(driverId);
  return iterator == registry().end() ? 0 : iterator->second.views.size();
}

bool hasActiveAnimation(uint64_t driverId) {
  auto iterator = registry().find(driverId);
  return iterator != registry().end() &&
      iterator->second.animation.has_value();
}

} // namespace smoothclip
