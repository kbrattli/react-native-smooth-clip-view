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
- (void)smoothClipCancelAnimationUsingTarget:(BOOL)useTarget;
- (BOOL)smoothClipIsJoinable;
- (BOOL)smoothClipCanDisplay;
- (double)smoothClipInheritedVelocityToPresentation:
    (smoothclip::Presentation)presentation;
- (void)smoothClipClearVelocitySamples;
@end

namespace smoothclip {
namespace {

using ViewKey = uintptr_t;

enum class Ownership { Interactive, Native };
enum class AnimationKind { Timing, Spring };

struct ActiveAnimation {
  int32_t animationId;
  int32_t completionTag = 0;
  // Zero identifies a single-driver animation. A non-zero value binds
  // the driver to an immutable group whose completion is aggregated once.
  int32_t groupId = 0;
  std::unordered_set<ViewKey> participants;
  bool finished = true;
  AnimationKind kind = AnimationKind::Timing;
  // Geometry the transition started from. Used when a view must join the
  // animation but there is no laid-out peer to sample presentation from.
  Presentation start{{0, 0, 0, 0, 0}, 0, 0};
  TimingAnimation timing{};
  SpringAnimation spring{};
  // False while a pre-ready run waits for its first displayable host. Host
  // loss after the run starts finishes it at the target.
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
  int32_t completionTag;
  std::vector<uint64_t> driverIds;
  std::unordered_set<uint64_t> remainingDriverIds;
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
void finishGroupForHostLoss(int32_t groupId);
DriverSnapshot snapshotForDriver(uint64_t driverId);

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
  const int32_t completionTag = state.animation.has_value()
      ? state.animation->completionTag
      : 0;
  state.animation.reset();
  if (groupId != 0) {
    groupMemberCompleted(groupId, driverId, finished);
    return;
  }
  {
    std::lock_guard<std::mutex> lock(completionSinkMutex());
    if (completionSink().callback) {
      completionSink().callback(
          driverId, animationId, completionTag, finished);
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
    int32_t completionTag,
    bool finished,
    const std::vector<uint64_t> &driverIds) {
  std::vector<DriverSnapshot> snapshots;
  snapshots.reserve(driverIds.size());
  for (const uint64_t driverId : driverIds) {
    snapshots.push_back(snapshotForDriver(driverId));
  }
  std::lock_guard<std::mutex> lock(completionSinkMutex());
  if (groupCompletionSink().callback) {
    groupCompletionSink().callback(
        controllerId,
        groupId,
        completionTag,
        finished,
        std::move(snapshots));
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
  const int32_t completionTag = group.completionTag;
  const bool aggregateFinished = group.finished;
  const std::vector<uint64_t> driverIds = group.driverIds;
  groupRegistry().erase(iterator);
  emitGroupCompletion(
      controllerId,
      groupId,
      completionTag,
      aggregateFinished,
      driverIds);
}

void emitStandaloneCompletion(
    uint64_t driverId,
    int32_t animationId,
    int32_t completionTag,
    bool finished) {
  {
    std::lock_guard<std::mutex> lock(completionSinkMutex());
    if (completionSink().callback) {
      completionSink().callback(
          driverId, animationId, completionTag, finished);
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
  // A pre-ready animation never rendered, so state.latest already holds its
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
               state.animation->participants.count(key) > 0) {
      // An installed participant whose HOST just lost its size still holds
      // real mid-flight geometry on its clip layer (host bounds do not feed
      // the clip container). Without this fallback, a sole running host
      // resized to zero must still freeze from its real clip layer rather
      // than state.latest, which already holds the target.
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

double resolvedSpringVelocity(
    const DriverState &state,
    const Presentation &target,
    const SpringAnimation &spring) {
  if (!spring.inheritVelocity) return spring.initialVelocity;
  for (const ViewKey key : state.views) {
    SmoothClipView *view = viewForKey(key);
    if ([view smoothClipIsJoinable]) {
      return [view smoothClipInheritedVelocityToPresentation:target];
    }
  }
  return 0;
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
      const bool wasPending = !state.animation->started;
      for (const ViewKey key : state.views) {
        [viewForKey(key) smoothClipCancelAnimationUsingTarget:YES];
      }
      if (wasPending) {
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
      const int32_t completionTag = remainingGroup.completionTag;
      const bool finished = remainingGroup.finished;
      const std::vector<uint64_t> completedDrivers =
          remainingGroup.driverIds;
      groupRegistry().erase(groupIterator);
      emitGroupCompletion(
          controllerId,
          groupId,
          completionTag,
          finished,
          completedDrivers);
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

void finishStandaloneAtTarget(uint64_t driverId, DriverState &state) {
  if (!state.animation.has_value()) return;
  if (state.animation->groupId != 0) {
    cancelGroupInternal(
        state.animation->groupId, GroupCancelBehavior::Finish, true);
    return;
  }
  const int32_t animationId = state.animation->animationId;
  for (const ViewKey key : state.views) {
    [viewForKey(key) smoothClipCancelAnimationUsingTarget:YES];
  }
  state.ownership = Ownership::Interactive;
  emitCompletion(driverId, state, animationId, true);
}

void finishIfNoInstalledParticipants(uint64_t driverId, DriverState &state) {
  if (!state.animation.has_value() || !state.animation->started ||
      !state.animation->participants.empty()) {
    return;
  }
  const int32_t animationId = state.animation->animationId;
  const bool finished = state.animation->finished;
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
  // Replacing a pre-ready animation (e.g. open→close before the host mounted):
  // it never rendered, and state.latest is its target — start from where the
  // clip actually is, the pending run's own start.
  if (state.animation.has_value() && !state.animation->started) {
    return state.animation->start;
  }
  return state.animation.has_value()
      ? canonicalVisiblePresentation(state)
      : state.latest;
}

// Installs a run that waited for its host to become displayable.
void installPendingAnimation(
    DriverState &state,
    SmoothClipView *view,
    ViewKey key,
    const Presentation &visible,
    CFTimeInterval sharedBeginTime = 0) {
  auto &active = *state.animation;
  BOOL installed = NO;
  if (active.kind == AnimationKind::Timing) {
    installed = [view smoothClipAnimateTiming:state.latest
                                    animation:active.timing
                                  animationId:active.animationId
                              sharedBeginTime:sharedBeginTime];
  } else if (active.kind == AnimationKind::Spring) {
    installed = [view smoothClipAnimateSpring:state.latest
                                    animation:active.spring
                                  animationId:active.animationId
                              sharedBeginTime:sharedBeginTime];
  }
  if (installed) {
    active.participants.insert(key);
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

void startPendingAnimation(DriverState &state) {
  if (state.animation->groupId != 0) {
    tryStartGroup(state.animation->groupId);
    return;
  }
  state.animation->started = true;
  // Participants describe live CA delegates, not registered views. Anything
  // left from the frozen run can only produce a stale callback for that run.
  state.animation->participants.clear();
  const Presentation start = state.animation->start;
  for (const ViewKey key : state.views) {
    SmoothClipView *participant = viewForKey(key);
    [participant smoothClipApplyPresentation:start recordVelocitySample:NO];
    installPendingAnimation(state, participant, key, start);
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
    active.started = true;
    active.participants.clear();
    const Presentation start = active.start;
    for (const ViewKey key : state.views) {
      SmoothClipView *participant = viewForKey(key);
      [participant smoothClipApplyPresentation:start recordVelocitySample:NO];
      installPendingAnimation(
          state, participant, key, start, sharedBeginTime);
    }
  }
  [CATransaction commit];
}

void finishGroupForHostLoss(int32_t groupId) {
  auto groupIterator = groupRegistry().find(groupId);
  if (groupIterator == groupRegistry().end() ||
      groupIterator->second.mutating) {
    return;
  }
  cancelGroupInternal(groupId, GroupCancelBehavior::Freeze, false);
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
    finishGroupForHostLoss(groupId);
  }
  for (auto &[driverId, state] : registry()) {
    if (!state.animation.has_value() || state.animation->groupId == 0) {
      finishStandaloneAtTarget(driverId, state);
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
      startPendingAnimation(state);
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
  const ViewKey key = keyForView(view);
  const auto existing = std::find(state.views.begin(), state.views.end(), key);
  if (existing == state.views.end() && !state.views.empty()) {
#if DEBUG
    NSCAssert(NO, @"One SmoothClip controller cannot drive two mounted hosts");
#endif
    return;
  }
  // Seed canonical geometry from the mounting view's initial props BEFORE
  // sampling `visible`; otherwise the first registration captures the default
  // empty {0,0,0,0} rect, seeding the view (and the presentation layer the
  // opening timing animation samples as its "from") to the top-left instead of
  // the real origin rectangle.
  if (!state.hasLatest) {
    state.latest = initialPresentation;
    state.hasLatest = true;
  }
  const bool hasPendingRun =
      state.animation.has_value() && !state.animation->started;
  // A pending run may only start once this view can produce a visible frame; a
  // registration from a detached subtree (transparentModal before its view
  // controller is presented) keeps it waiting; a positive
  // displayability update starts it inside the attach commit.
  const bool startsPendingRun =
      hasPendingRun && [view smoothClipCanDisplay];
  Presentation visible = state.latest;
  if (hasPendingRun) {
    // state.latest already holds the target; applying it here is
    // exactly the jump this path exists to avoid.
    visible = state.animation->start;
  }
  if (existing == state.views.end()) {
    state.views.push_back(key);
  }
  [view smoothClipApplyPresentation:visible recordVelocitySample:NO];
  if (startsPendingRun) {
    startPendingAnimation(state);
  }
}

void viewDisplayabilityChanged(uint64_t driverId, SmoothClipView *view) {
  NSCAssert(NSThread.isMainThread, @"SmoothClip registry is main-thread only");
  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return;
  DriverState &state = iterator->second;
  if (!state.animation.has_value()) return;
  const ViewKey key = keyForView(view);
  if (std::find(state.views.begin(), state.views.end(), key) ==
      state.views.end()) {
    return;
  }
  if (![view smoothClipCanDisplay]) {
    if (state.animation->groupId != 0 && state.animation->started) {
      finishGroupForHostLoss(state.animation->groupId);
    } else if (state.animation->started) {
      finishStandaloneAtTarget(driverId, state);
    }
    return;
  }
  if (!state.animation->started) {
    if (state.animation->groupId != 0) {
      tryStartGroup(state.animation->groupId);
    } else {
      startPendingAnimation(state);
    }
  }
}

void unregisterView(uint64_t driverId, SmoothClipView *view) {
  NSCAssert(NSThread.isMainThread, @"SmoothClip registry is main-thread only");
  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return;
  DriverState &state = iterator->second;
  const ViewKey key = keyForView(view);
  if (state.animation.has_value()) {
    if (state.animation->groupId != 0 && state.animation->started) {
      finishGroupForHostLoss(state.animation->groupId);
    } else if (state.animation->groupId == 0 && state.animation->started) {
      finishStandaloneAtTarget(driverId, state);
    }
  }
  state.views.erase(
      std::remove(state.views.begin(), state.views.end(), key),
      state.views.end());
  if (state.destroyed && state.views.empty()) registry().erase(iterator);
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
            signpostLog(), identifier, "lookup-fanout", "ignored=pending-run");
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

Presentation beginInteraction(uint64_t driverId) {
  if (!NSThread.isMainThread) {
    // See setPresentation: blocking off-main risks a deadlock, so the call
    // fails defined and the JS side keeps its current value.
    return unavailablePresentation();
  }
  auto iterator = registry().find(driverId);
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
        !canonicalizePresentation(entry.target)) {
      return false;
    }
  }
  if (kind == AnimationKind::Timing &&
      !isValidTiming(timing)) {
    return false;
  }
  if (kind == AnimationKind::Spring &&
      (!isValidSpring(spring) || spring.inheritVelocity)) {
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
        !isAutonomousUniformCircular(resolvedStart) ||
        !isAutonomousUniformCircular(entry.target)) {
      return false;
    }
    if (kind == AnimationKind::Spring) {
      const double velocity = spring.initialVelocity;
      if (!springScaleStaysPositive(
              resolvedStart, entry.target, spring, velocity)) {
        return false;
      }
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
    int32_t completionTag) {
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
    emitGroupCompletion(
        controllerId, groupId, completionTag, true, driverIds);
    return groupId;
  }

  GroupState group{
      controllerId,
      groupId,
      completionTag,
      driverIds,
      std::unordered_set<uint64_t>(driverIds.begin(), driverIds.end()),
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
    state.latest = entry.target;
    state.hasLatest = true;
    state.ownership = Ownership::Native;

    ActiveAnimation active{groupId};
    active.groupId = groupId;
    active.kind = kind;
    active.start = start;
    active.timing = timing;
    active.spring = spring;
    if (kind == AnimationKind::Spring) {
      active.spring.initialVelocity = spring.initialVelocity;
      active.spring.inheritVelocity = false;
    }
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
    int32_t completionTag,
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
      completionTag);
}

int32_t animateSpringGroup(
    uint64_t controllerId,
    std::vector<GroupMotionEntry> entries,
    SpringAnimation animation,
    int32_t completionTag,
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
      completionTag);
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
    TimingAnimation animation,
    int32_t completionTag) {
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
    emitStandaloneCompletion(
        driverId, animationId, completionTag, true);
    return animationId;
  }

  ActiveAnimation active{animationId};
  active.completionTag = completionTag;
  active.kind = AnimationKind::Timing;
  active.start = resolvedStart;
  active.timing = animation;
  active.started = anyDisplayableView(state);
  state.animation = std::move(active);
  if (!state.animation->started) {
    // No host can display yet. Ownership stays Native and the first
    // displayable registration starts the full run. A non-zero ID still
    // distinguishes this pending run from rejection.
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
    SpringAnimation animation,
    int32_t completionTag) {
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
  const double velocity = iterator == registry().end()
      ? animation.initialVelocity
      : resolvedSpringVelocity(iterator->second, presentation, animation);
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
  state.destroyed = false;
  const int32_t animationId = allocateAnimationId();
  const Presentation resolvedStart = preflightStart;
  prepareAnimation(driverId, state, start, presentation);

  if (shouldReduceMotion(animation.reduceMotion)) {
    applyPresentation(state, presentation, false);
    emitStandaloneCompletion(
        driverId, animationId, completionTag, true);
    return animationId;
  }

  ActiveAnimation active{animationId};
  active.completionTag = completionTag;
  active.kind = AnimationKind::Spring;
  active.start = resolvedStart;
  active.spring = animation;
  active.spring.initialVelocity = velocity;
  active.spring.inheritVelocity = false;
  active.started = anyDisplayableView(state);
  state.animation = std::move(active);
  if (!state.animation->started) {
    // Pending until the first displayable view — see animateTiming.
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
                                      animation:state.animation->spring
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
  emitStandaloneCompletion(driverId, animationId, 0, false);
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
    // A pending run never dispatched to its view, so the host still has
    // _activeAnimationId == 0 and smoothClipCancelAnimationUsingTarget
    // early-returns without writing anything: state.latest would report the
    // target while every layer still showed the pre-animation geometry, and
    // nothing else re-applies it. Android's cancelAnimation fans the result out
    // unconditionally — match that. Read `started` before cancelActive, which
    // resets state.animation.
    //
    // Gated on the pending case so a started animation is not written twice
    // (smoothClipCancelAnimationUsingTarget already applied the target there),
    // and applied WITHOUT a velocity sample: a jump to the target is not
    // interactive motion, and the cancel-to-target path deliberately keeps it
    // out of the 'inherit' history on both platforms — Android's cancel
    // fan-out records nothing either.
    const bool wasPending = !state.animation->started;
    cancelActive(driverId, state, true);
    if (wasPending) {
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
  // A pre-ready run has no installed delegate; it completes only through
  // replacement, cancellation, host loss, or controller destruction.
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
