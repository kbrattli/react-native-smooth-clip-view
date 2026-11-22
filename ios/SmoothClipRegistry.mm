#import "SmoothClipViewRegistry.h"

#import "SmoothClipBackdropView.h"
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
#include "SmoothClipFlightGeometry.h"
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
- (BOOL)smoothClipPauseSpringAnimation:(int32_t)animationId
                           atMediaTime:(CFTimeInterval)mediaTime;
- (BOOL)smoothClipResumeSpringAnimation:(int32_t)animationId
                            atMediaTime:(CFTimeInterval)mediaTime
                             catchUpBy:(CFTimeInterval)catchUp;
- (BOOL)smoothClipHasInstalledAnimation:(int32_t)animationId;
- (BOOL)smoothClipIsJoinable;
- (BOOL)smoothClipCanDisplay;
// Flights (SmoothClipView.mm, "Flights").
- (BOOL)smoothClipFlightWantsLift;
- (BOOL)smoothClipFlightLifted;
- (void)smoothClipLiftForFlightWithRest:(smoothclip::Presentation)rest
                            interaction:(BOOL)interaction;
- (void)smoothClipFlightRunDidEnd:(BOOL)finished;
- (BOOL)smoothClipFlightWayBackFrom:(smoothclip::Presentation *)from;
- (void)smoothClipFlightForgetLanding;
- (BOOL)smoothClipWindowTransform:(smoothclip::HostWindowTransform *)transform;
- (void)smoothClipDetachFlightForHostLoss;
- (CALayer *)smoothClipRenderLayer;
- (double)smoothClipInheritedVelocityToPresentation:
    (smoothclip::Presentation)presentation;
- (void)smoothClipClearVelocitySamples;
@end

@interface SmoothClipBackdropView (Registry)
- (CGPoint)smoothClipBackdropCurrentTranslation;
- (void)smoothClipApplyBackdrop:(CGPoint)translation;
- (BOOL)smoothClipAnimateBackdropTo:(CGPoint)target
                             timing:(smoothclip::TimingAnimation)timing
                    sharedBeginTime:(CFTimeInterval)sharedBeginTime;
- (BOOL)smoothClipAnimateBackdropTo:(CGPoint)target
                             spring:(smoothclip::SpringAnimation)spring
                    sharedBeginTime:(CFTimeInterval)sharedBeginTime;
- (void)smoothClipCancelBackdropUsingTarget:(BOOL)useTarget;
- (BOOL)smoothClipPauseBackdropAtMediaTime:(CFTimeInterval)mediaTime;
- (BOOL)smoothClipResumeBackdropAtMediaTime:(CFTimeInterval)mediaTime
                                  catchUpBy:(CFTimeInterval)catchUp;
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
  // The run's epoch (media time): the `beginTime` its layers were installed
  // with, which is the install. A run that replaces it reads its motion
  // (`velocity: 'inherit'`) at `now - beginTime`, the call, and starts where
  // this run's layers show it then.
  // A spring paused for inactivity holds its motion at `pausedAt`, and its
  // epoch moves forward when it resumes, as its layers' does.
  CFTimeInterval beginTime = 0;
  CFTimeInterval pausedAt = 0;
  bool exposedToInactivity = false;
  bool needsForegroundReconciliation = false;
};

struct DriverState {
  Presentation latest{{0, 0, 0, 0, 0}, 0, 0};
  bool hasLatest = false;
  Ownership ownership = Ownership::Interactive;
  std::vector<ViewKey> views;
  // Backdrop views bound to the driver: translated by the presentation's
  // backdrop channel on every write and animated on every run's epoch.
  std::vector<ViewKey> backdrops;
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

std::optional<CFTimeInterval> &applicationInactiveSince() {
  static std::optional<CFTimeInterval> value;
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
SmoothClipView *viewForKey(ViewKey key);
SmoothClipBackdropView *backdropForKey(ViewKey key);

bool animationNeedsForegroundReconciliation(const DriverState &state) {
  if (!state.animation.has_value()) return false;
  const ActiveAnimation &animation = *state.animation;
  if (animation.needsForegroundReconciliation) return true;
  if (!animation.exposedToInactivity) return false;
  if (animation.participants.empty()) return true;
  for (const ViewKey key : animation.participants) {
    if (![viewForKey(key)
            smoothClipHasInstalledAnimation:animation.animationId]) {
      return true;
    }
  }
  return false;
}

bool groupNeedsForegroundReconciliation(int32_t groupId) {
  const auto groupIterator = groupRegistry().find(groupId);
  if (groupIterator == groupRegistry().end()) return false;
  for (const uint64_t driverId : groupIterator->second.driverIds) {
    const auto stateIterator = registry().find(driverId);
    if (stateIterator != registry().end() &&
        stateIterator->second.animation.has_value() &&
        stateIterator->second.animation->groupId == groupId &&
        animationNeedsForegroundReconciliation(stateIterator->second)) {
      return true;
    }
  }
  return false;
}

bool pauseSpringForInactivity(
    DriverState &state,
    CFTimeInterval mediaTime) {
  if (!state.animation.has_value() || !state.animation->started ||
      state.animation->kind != AnimationKind::Spring) {
    return true;
  }
  ActiveAnimation &animation = *state.animation;
  if (animation.participants.empty()) {
    animation.needsForegroundReconciliation = true;
    return false;
  }
  bool paused = true;
  for (const ViewKey key : animation.participants) {
    paused = [viewForKey(key)
        smoothClipPauseSpringAnimation:animation.animationId
                           atMediaTime:mediaTime] && paused;
  }
  for (const ViewKey key : state.backdrops) {
    [backdropForKey(key) smoothClipPauseBackdropAtMediaTime:mediaTime];
  }
  if (paused) animation.pausedAt = mediaTime;
  if (!paused) animation.needsForegroundReconciliation = true;
  return paused;
}

bool resumeSpringAfterInactivity(
    DriverState &state,
    CFTimeInterval mediaTime,
    CFTimeInterval catchUp) {
  if (!state.animation.has_value() || !state.animation->started ||
      state.animation->kind != AnimationKind::Spring) {
    return true;
  }
  ActiveAnimation &animation = *state.animation;
  bool resumed = !animation.participants.empty();
  for (const ViewKey key : animation.participants) {
    resumed = [viewForKey(key)
        smoothClipResumeSpringAnimation:animation.animationId
                            atMediaTime:mediaTime
                             catchUpBy:catchUp] && resumed;
  }
  for (const ViewKey key : state.backdrops) {
    [backdropForKey(key) smoothClipResumeBackdropAtMediaTime:mediaTime
                                                   catchUpBy:catchUp];
  }
  if (animation.pausedAt > 0) {
    // The layers resume `catchUp` past where they paused (beginTime =
    // now - (pausedElapsed + catchUp)); the epoch follows them.
    animation.beginTime += mediaTime - animation.pausedAt - catchUp;
    animation.pausedAt = 0;
  }
  if (!resumed) animation.needsForegroundReconciliation = true;
  return resumed;
}

bool resumeGroupSpringsAfterInactivity(
    int32_t groupId,
    CFTimeInterval mediaTime,
    CFTimeInterval catchUp) {
  const auto groupIterator = groupRegistry().find(groupId);
  if (groupIterator == groupRegistry().end()) return false;
  bool resumed = true;
  for (const uint64_t driverId : groupIterator->second.driverIds) {
    const auto stateIterator = registry().find(driverId);
    if (stateIterator == registry().end() ||
        !stateIterator->second.animation.has_value() ||
        stateIterator->second.animation->groupId != groupId) {
      return false;
    }
    resumed = resumeSpringAfterInactivity(
        stateIterator->second, mediaTime, catchUp) && resumed;
  }
  return resumed;
}

void clearGroupInactivityExposure(int32_t groupId) {
  const auto groupIterator = groupRegistry().find(groupId);
  if (groupIterator == groupRegistry().end()) return;
  for (const uint64_t driverId : groupIterator->second.driverIds) {
    const auto stateIterator = registry().find(driverId);
    if (stateIterator != registry().end() &&
        stateIterator->second.animation.has_value() &&
        stateIterator->second.animation->groupId == groupId) {
      stateIterator->second.animation->exposedToInactivity = false;
      stateIterator->second.animation->needsForegroundReconciliation = false;
    }
  }
}

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

ViewKey keyForBackdrop(SmoothClipBackdropView *view) {
  return reinterpret_cast<ViewKey>((__bridge void *)view);
}

SmoothClipBackdropView *backdropForKey(ViewKey key) {
  return (__bridge SmoothClipBackdropView *)(reinterpret_cast<void *>(key));
}

CGPoint backdropTranslation(const Presentation &presentation) {
  return CGPointMake(
      presentation.backdropTranslateX, presentation.backdropTranslateY);
}

// The clip host knows nothing of the backdrop channel, so a presentation
// read back from it carries none. A bound backdrop's visible translation is
// the truth; without one, the driver's model (a pending run's start, else the
// latest target).
void overlayBackdrop(const DriverState &state, Presentation &presentation) {
  if (!state.backdrops.empty()) {
    const CGPoint translation = [backdropForKey(state.backdrops.front())
        smoothClipBackdropCurrentTranslation];
    presentation.backdropTranslateX = translation.x;
    presentation.backdropTranslateY = translation.y;
    return;
  }
  const Presentation &model =
      state.animation.has_value() && !state.animation->started
      ? state.animation->start
      : state.latest;
  presentation.backdropTranslateX = model.backdropTranslateX;
  presentation.backdropTranslateY = model.backdropTranslateY;
}

void applyBackdrops(const DriverState &state, const Presentation &presentation) {
  const CGPoint translation = backdropTranslation(presentation);
  for (const ViewKey key : state.backdrops) {
    [backdropForKey(key) smoothClipApplyBackdrop:translation];
  }
}

void cancelBackdrops(const DriverState &state, bool useTarget) {
  for (const ViewKey key : state.backdrops) {
    [backdropForKey(key) smoothClipCancelBackdropUsingTarget:useTarget];
  }
}

// Freezes every bound backdrop where it is and reads the channel back into
// the frozen presentation.
void freezeBackdropsInto(const DriverState &state, Presentation &presentation) {
  cancelBackdrops(state, false);
  overlayBackdrop(state, presentation);
}

// Runs the pending animation's backdrop channel on every bound backdrop, on
// the same epoch as the clip's group. An inherited spring velocity was
// resolved once by the registry before dispatch (inheritedVelocityFor, per
// driver), so `active.spring` carries the same trajectory the clip host runs.
void installBackdropAnimations(
    const DriverState &state,
    CFTimeInterval sharedBeginTime) {
  if (!state.animation.has_value() || state.backdrops.empty()) return;
  const ActiveAnimation &active = *state.animation;
  const CGPoint target = backdropTranslation(state.latest);
  for (const ViewKey key : state.backdrops) {
    SmoothClipBackdropView *backdrop = backdropForKey(key);
    if (active.kind == AnimationKind::Timing) {
      [backdrop smoothClipAnimateBackdropTo:target
                                     timing:active.timing
                            sharedBeginTime:sharedBeginTime];
    } else {
      [backdrop smoothClipAnimateBackdropTo:target
                                     spring:active.spring
                            sharedBeginTime:sharedBeginTime];
    }
  }
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
  // A flying host lands once the run is gone. A finished run is never being
  // replaced, so its host lands here, before the completion below reads the
  // registry: a handoff resets the driver to rest through settleFlightHost
  // (no other registry call), and JS receives the frame the host shows, as
  // on Android. Any other end defers the landing to the main queue, so that
  // a replacement run that follows in this same call continues the lift.
  const std::vector<ViewKey> views = state.views;
  for (const ViewKey key : views) {
    [viewForKey(key) smoothClipFlightRunDidEnd:finished];
  }
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
  freezeBackdropsInto(state, canonical);
  return canonical;
}

Presentation canonicalVisiblePresentation(const DriverState &state) {
  if (state.animation.has_value() && !state.animation->started) {
    return state.animation->start;
  }
  for (const ViewKey key : state.views) {
    SmoothClipView *candidate = viewForKey(key);
    if ([candidate smoothClipIsJoinable]) {
      Presentation visible = [candidate smoothClipCurrentPresentation];
      overlayBackdrop(state, visible);
      return visible;
    }
  }
  return state.latest;
}

// What a snapshot reports as ready: a host on screen, not only one that can get
// there. A freshly mounted host can display at once, but its layer only reaches
// the render server with the next Core Animation commit, and a presentation
// layer exists from then on. Runs start on anyDisplayableView instead: nothing
// would wake a pending run when that commit lands.
bool driverReady(const DriverState &state) {
  if (state.destroyed) return false;
  for (const ViewKey key : state.views) {
    SmoothClipView *view = viewForKey(key);
    if ([view smoothClipCanDisplay] &&
        [view smoothClipRenderLayer].presentationLayer != nil) {
      return true;
    }
  }
  return false;
}

// A started run's progress along its own curve at media time `at`: read at
// `at - beginTime`, or at `pausedAt` while a spring is paused for inactivity
// (its layers hold that frame). Springs use what Core Animation runs.
RunProgress startedRunProgressAt(
    const ActiveAnimation &run,
    CFTimeInterval at) {
  const double elapsedS =
      (run.pausedAt > 0 ? run.pausedAt : at) - run.beginTime;
  return run.kind == AnimationKind::Spring
      ? coreAnimationSpringRunProgress(run.spring, elapsedS)
      : timingRunProgress(run.timing, elapsedS);
}

// `velocity: 'inherit'` for one driver (flight-spec.md), resolved before the
// call changes anything, against the start the new run begins at and its
// target:
//   1. a started run that the call replaces hands over its own velocity at
//      `at`, the call: its curve read at `at - beginTime`, projected onto
//      the new run's displacement (start -> target);
//   2. otherwise the motion of the frames an interaction wrote;
//   3. otherwise 0.
// Same units as an explicit velocity: 1 covers the remaining distance in one
// second. The math is shared with Android (cpp/SmoothClipFlightGeometry.h).
double inheritedVelocityFor(
    const DriverState &state,
    const Presentation &start,
    const Presentation &target,
    CFTimeInterval at) {
  if (state.animation.has_value() && state.animation->started) {
    const ActiveAnimation &run = *state.animation;
    // A started run's target is the driver's latest presentation.
    return inheritedRunVelocityFrom(
        run.start, state.latest, startedRunProgressAt(run, at), start,
        target);
  }
  for (const ViewKey key : state.views) {
    SmoothClipView *view = viewForKey(key);
    if ([view smoothClipIsJoinable]) {
      return [view smoothClipInheritedVelocityToPresentation:target];
    }
  }
  return 0;
}

double resolvedSpringVelocity(
    const DriverState &state,
    const Presentation &start,
    const Presentation &target,
    const SpringAnimation &spring) {
  if (!spring.inheritVelocity) return spring.initialVelocity;
  return inheritedVelocityFor(state, start, target, CACurrentMediaTime());
}

// What a flight host shows right now, with the driver's backdrop channel: a
// handoff puts the host back there. Read before a pending run is marked
// started, so a run's own start never counts as the rest.
Presentation flightRestPresentation(
    const DriverState &state,
    SmoothClipView *view) {
  Presentation rest = [view smoothClipCurrentPresentation];
  overlayBackdrop(state, rest);
  return rest;
}

bool flightWayBackStart(const DriverState &state, Presentation &start);
void applyPresentation(
    DriverState &state,
    Presentation presentation,
    bool recordVelocitySample);

// Lifts the driver's flight hosts into the window's flight layer: before a
// run's start applies, or when an interaction begins (spec: Lift). An
// interaction on a host whose flight handed off to a target that is still
// attached and visible starts where that flight landed, as a run on the way
// back does: the lift hides the target, so the content must not jump back to
// the rest frame.
void liftFlightHosts(DriverState &state, bool interaction) {
  Presentation landed;
  const bool wayBack = interaction && flightWayBackStart(state, landed);
  for (const ViewKey key : state.views) {
    SmoothClipView *view = viewForKey(key);
    if (![view smoothClipFlightWantsLift]) continue;
    const Presentation rest = [view smoothClipFlightLifted]
        ? state.latest
        : flightRestPresentation(state, view);
    [view smoothClipLiftForFlightWithRest:rest interaction:interaction];
  }
  if (wayBack) applyPresentation(state, landed, false);
}

// Window-space input (SmoothClipPresentation.space = 'window') in host space,
// through the driver's host transform to its window: the one captured at
// lift while the host flies, the model one otherwise. False without a host,
// or when the transform rotates, skews or scales unevenly.
bool resolveWindowSpace(uint64_t driverId, Presentation &presentation) {
  const auto iterator = registry().find(driverId);
  if (iterator == registry().end() || iterator->second.views.empty()) {
    return false;
  }
  SmoothClipView *host = viewForKey(iterator->second.views.front());
  HostWindowTransform transform;
  if (![host smoothClipWindowTransform:&transform]) return false;
  const CGSize size = host.bounds.size;
  presentation = presentationFromWindowSpace(
      presentation, transform, size.width, size.height);
  return true;
}

// The way back (spec: The way back): where the host's last flight landed,
// while the target it handed off to is attached and visible.
bool flightWayBackStart(const DriverState &state, Presentation &start) {
  if (state.animation.has_value()) return false;
  for (const ViewKey key : state.views) {
    Presentation landed;
    if ([viewForKey(key) smoothClipFlightWayBackFrom:&landed] &&
        canonicalizePresentation(landed)) {
      start = landed;
      return true;
    }
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
      const bool wasPending = !state.animation->started;
      for (const ViewKey key : state.views) {
        [viewForKey(key) smoothClipCancelAnimationUsingTarget:YES];
      }
      cancelBackdrops(state, true);
      if (wasPending) {
        for (const ViewKey key : state.views) {
          [viewForKey(key) smoothClipApplyPresentation:resolved
                                  recordVelocitySample:NO];
        }
        applyBackdrops(state, resolved);
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
    // A finished flight that handed off is back at rest now.
    snapshots.push_back({driverId, state.latest, ready});
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
  cancelBackdrops(state, useTarget);
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
  cancelBackdrops(state, true);
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
  cancelBackdrops(state, true);
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
  applyBackdrops(state, presentation);
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
  // The views install with no shared epoch: they begin now.
  state.animation->beginTime = CACurrentMediaTime();
  // Participants describe live CA delegates, not registered views. Anything
  // left from the frozen run can only produce a stale callback for that run.
  state.animation->participants.clear();
  const Presentation start = state.animation->start;
  for (const ViewKey key : state.views) {
    SmoothClipView *participant = viewForKey(key);
    [participant smoothClipApplyPresentation:start recordVelocitySample:NO];
    installPendingAnimation(state, participant, key, start);
  }
  installBackdropAnimations(state, 0);
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
        stateIterator->second.animation->started ||
        stateIterator->second.destroyed ||
        !anyDisplayableView(stateIterator->second)) {
      return;
    }
  }

  // Every participant begins at this install, on one epoch, as a Core
  // Animation run committed now would: its first frame drawn already moves,
  // and no frame skips ahead. The caller's frame stamp is not used. It names
  // the display link's target vsync, which can lie a frame on either side of
  // the install, so a `withTiming` begun in the same UI frame can lead or
  // trail this run by up to a frame. Code that continues from the run reads
  // the frame `beginInteraction()` returns, not a model of it.
  const CFTimeInterval sharedBeginTime = CACurrentMediaTime();
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  for (const uint64_t driverId : driverIds) {
    DriverState &state = registry().find(driverId)->second;
    // Flight hosts leave their screen in the run's own transaction, from
    // what they show now, before the start applies.
    liftFlightHosts(state, false);
    ActiveAnimation &active = *state.animation;
    active.started = true;
    active.beginTime = sharedBeginTime;
    active.participants.clear();
    const Presentation start = active.start;
    for (const ViewKey key : state.views) {
      SmoothClipView *participant = viewForKey(key);
      [participant smoothClipApplyPresentation:start recordVelocitySample:NO];
      installPendingAnimation(
          state, participant, key, start, sharedBeginTime);
    }
    installBackdropAnimations(state, sharedBeginTime);
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
  const CFTimeInterval mediaTime = CACurrentMediaTime();
  applicationActiveState() = false;
  applicationInactiveSince() = mediaTime;
  for (auto &[driverId, state] : registry()) {
    (void)driverId;
    if (state.animation.has_value() && state.animation->started) {
      state.animation->exposedToInactivity = true;
      pauseSpringForInactivity(state, mediaTime);
    }
  }
}

void applicationDidBecomeActive() {
  NSCAssert(NSThread.isMainThread, @"SmoothClip registry is main-thread only");
  if (applicationActiveState()) return;
  const CFTimeInterval mediaTime = CACurrentMediaTime();
  const CFTimeInterval inactiveDuration = applicationInactiveSince().has_value()
      ? std::max((CFTimeInterval)0,
                 mediaTime - *applicationInactiveSince())
      : 0;
  const CFTimeInterval springCatchUp =
      std::min((CFTimeInterval)0.064, inactiveDuration);
  applicationInactiveSince().reset();
  applicationActiveState() = true;
  std::vector<int32_t> groupIds;
  groupIds.reserve(groupRegistry().size());
  for (const auto &[groupId, group] : groupRegistry()) {
    (void)group;
    groupIds.push_back(groupId);
  }
  for (const int32_t groupId : groupIds) {
    bool needsReconciliation = groupNeedsForegroundReconciliation(groupId);
    if (!needsReconciliation) {
      needsReconciliation = !resumeGroupSpringsAfterInactivity(
          groupId, mediaTime, springCatchUp);
    }
    if (needsReconciliation) {
      cancelGroupInternal(groupId, GroupCancelBehavior::Finish, true);
    } else {
      clearGroupInactivityExposure(groupId);
      tryStartGroup(groupId);
    }
  }
  for (auto &[driverId, state] : registry()) {
    if (!state.animation.has_value() || state.animation->groupId != 0) {
      continue;
    }
    bool needsReconciliation = animationNeedsForegroundReconciliation(state);
    if (!needsReconciliation) {
      needsReconciliation = !resumeSpringAfterInactivity(
          state, mediaTime, springCatchUp);
    }
    if (needsReconciliation) {
      finishStandaloneAtTarget(driverId, state);
    } else {
      state.animation->exposedToInactivity = false;
      state.animation->needsForegroundReconciliation = false;
      if (!state.animation->started && anyDisplayableView(state)) {
        startPendingAnimation(state);
      }
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
  applyBackdrops(state, visible);
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
    if (!applicationActiveState()) {
      return;
    }
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
    if (!applicationActiveState() && state.animation->started) {
      state.animation->participants.erase(key);
      state.animation->needsForegroundReconciliation = true;
    } else if (state.animation->groupId != 0 && state.animation->started) {
      finishGroupForHostLoss(state.animation->groupId);
    } else if (state.animation->groupId == 0 && state.animation->started) {
      finishStandaloneAtTarget(driverId, state);
    }
  }
  state.views.erase(
      std::remove(state.views.begin(), state.views.end(), key),
      state.views.end());
  if (state.destroyed && state.views.empty() && state.backdrops.empty()) {
    registry().erase(iterator);
  }
}

void registerBackdropView(uint64_t driverId, SmoothClipBackdropView *view) {
  NSCAssert(NSThread.isMainThread, @"SmoothClip registry is main-thread only");
  auto &state = registry()[driverId];
  const ViewKey key = keyForBackdrop(view);
  if (std::find(state.backdrops.begin(), state.backdrops.end(), key) !=
      state.backdrops.end()) {
    return;
  }
  // Adopt the driver's current value: a pending run's start, an already
  // bound backdrop's visible value mid-run, else the model. A backdrop bound
  // while a run is in flight follows from the next run.
  Presentation visible =
      state.animation.has_value() && !state.animation->started
      ? state.animation->start
      : state.latest;
  if (!state.backdrops.empty()) overlayBackdrop(state, visible);
  state.backdrops.push_back(key);
  if (state.hasLatest) {
    [view smoothClipApplyBackdrop:backdropTranslation(visible)];
  }
}

void unregisterBackdropView(uint64_t driverId, SmoothClipBackdropView *view) {
  NSCAssert(NSThread.isMainThread, @"SmoothClip registry is main-thread only");
  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return;
  DriverState &state = iterator->second;
  const ViewKey key = keyForBackdrop(view);
  state.backdrops.erase(
      std::remove(state.backdrops.begin(), state.backdrops.end(), key),
      state.backdrops.end());
  if (state.destroyed && state.views.empty() && state.backdrops.empty()) {
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
    liftFlightHosts(state, true);
    return state.latest;
  }

  if (state.animation->groupId != 0) {
    const int32_t groupId = state.animation->groupId;
    cancelGroupInternal(
        groupId, GroupCancelBehavior::Freeze, false);
    const auto current = registry().find(driverId);
    if (current == registry().end()) return unavailablePresentation();
    liftFlightHosts(current->second, true);
    return current->second.latest;
  }

  const int32_t animationId = state.animation->animationId;
  const Presentation canonical = canonicalFrozenPresentation(state);
  state.latest = canonical;
  state.hasLatest = true;
  state.ownership = Ownership::Interactive;
  emitCompletion(driverId, state, animationId, false);
  liftFlightHosts(state, true);
  return state.latest;
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
    // A flight host follows the interaction in the flight layer; the next
    // run continues in the same lift.
    liftFlightHosts(state, true);
    snapshots.push_back(
        {driverId, state.latest, driverReady(state)});
  }
  return snapshots;
}

bool setPresentationBatch(const std::vector<BatchEntry> &entries) {
  if (!NSThread.isMainThread) return false;
  std::vector<BatchEntry> canonicalEntries = entries;
  for (BatchEntry &entry : canonicalEntries) {
    // Window-space frames resolve before anything else; one that cannot
    // (no host, or a rotated one) rejects the whole batch.
    if (entry.inWindow &&
        !resolveWindowSpace(entry.driverId, entry.presentation)) {
      return false;
    }
    entry.inWindow = false;
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
    DriverState &state = registry().find(entry.driverId)->second;
    applyPresentation(state, entry.presentation, true);
    for (const ViewKey key : state.views) {
      [viewForKey(key) smoothClipFlightForgetLanding];
    }
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
    std::vector<Presentation> &resolvedStarts,
    std::vector<double> &velocities) {
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
  if (kind == AnimationKind::Spring && !isValidSpring(spring)) {
    return false;
  }
  reduced = shouldReduceMotion(reduceMotion) ||
      (kind != AnimationKind::Spring && durationMs <= 0);
  std::unordered_set<uint64_t> unique;
  resolvedStarts.clear();
  resolvedStarts.reserve(entries.size());
  velocities.clear();
  velocities.reserve(entries.size());
  // One clock reading for the whole call: every replaced run hands over its
  // motion at the same instant, now, and the new run begins at its install
  // from what the host shows then.
  const CFTimeInterval now = CACurrentMediaTime();
  for (const GroupMotionEntry &entry : entries) {
    if (entry.driverId == 0 || !unique.insert(entry.driverId).second) {
      return false;
    }
    const auto iterator = registry().find(entry.driverId);
    const bool hasState = iterator != registry().end() &&
        !iterator->second.destroyed && iterator->second.hasLatest;
    if (!hasState && !entry.hasFrom) {
      return false;
    }
    Presentation resolvedStart;
    bool wayBack = false;
    if (entry.hasFrom) {
      resolvedStart = entry.from;
    } else if (flightWayBackStart(iterator->second, resolvedStart)) {
      wayBack = true;
    } else {
      resolvedStart = canonicalVisiblePresentation(iterator->second);
    }
    if (!isFinitePresentation(resolvedStart) ||
        !isFinitePresentation(entry.target) ||
        !isAutonomousUniformPair(resolvedStart, entry.target)) {
      return false;
    }
    double velocity = 0;
    if (kind == AnimationKind::Spring) {
      // `velocity: 'inherit'`, per driver. The way back starts on the target
      // where the flight landed, a frame nothing moved to: it inherits 0, as
      // a driver with no state does.
      velocity = !spring.inheritVelocity ? spring.initialVelocity
          : hasState && !wayBack
          ? inheritedVelocityFor(
                iterator->second, resolvedStart, entry.target, now)
          : 0.0;
      if (!std::isfinite(velocity) ||
          !springScaleStaysPositive(
              resolvedStart, entry.target, spring, velocity)) {
        return false;
      }
    }
    resolvedStarts.push_back(resolvedStart);
    velocities.push_back(velocity);
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
  std::vector<double> velocities;
  bool reduced = false;
  if (!NSThread.isMainThread || controllerId == 0) return 0;
  // Window-space endpoints resolve before preflight and canonicalization,
  // through each driver's host; one that cannot rejects the whole call.
  for (GroupMotionEntry &entry : entries) {
    if (entry.targetInWindow &&
        !resolveWindowSpace(entry.driverId, entry.target)) {
      return 0;
    }
    if (entry.hasFrom && entry.fromInWindow &&
        !resolveWindowSpace(entry.driverId, entry.from)) {
      return 0;
    }
    entry.targetInWindow = false;
    entry.fromInWindow = false;
  }
  if (!preflightGroupEntries(
          entries,
          kind,
          timing,
          spring,
          durationMs,
          reduceMotion,
          reduced,
          resolvedStarts,
          velocities)) {
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
      // Each driver runs with its own resolved velocity; the backdrop
      // channel follows the same trajectory.
      active.spring.initialVelocity = velocities[entryIndex];
      active.spring.inheritVelocity = false;
    }
    active.started = false;
    state.animation = std::move(active);
  }
  tryStartGroup(groupId);
  return groupId;
}

} // namespace

// The frame stamp is Android's (its frame loop advances from it); a run here
// begins at its install (tryStartGroup).
int32_t animateTimingGroup(
    uint64_t controllerId,
    std::vector<GroupMotionEntry> entries,
    TimingAnimation animation,
    int32_t completionTag,
    double /* startedAtHintS */) {
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
    double /* startedAtHintS */) {
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
  if (active.started) active.beginTime = CACurrentMediaTime();
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
  installBackdropAnimations(state, 0);
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
      : resolvedSpringVelocity(
            iterator->second, preflightStart, presentation, animation);
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
  if (active.started) active.beginTime = CACurrentMediaTime();
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
  installBackdropAnimations(state, 0);
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
      applyBackdrops(state, target);
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
  // A route unmount destroys the controller while its hero flies back in
  // the flight layer: that flight lands on its own (host loss).
  for (const ViewKey key : state.views) {
    [viewForKey(key) smoothClipDetachFlightForHostLoss];
  }
  cancelActive(driverId, state, false);
  // A destroyed driver's interaction history must not seed a revived
  // incarnation: the revival seed would otherwise pair with these samples and
  // refresh the staleness clock with motion no finger produced.
  for (const ViewKey key : state.views) {
    [viewForKey(key) smoothClipClearVelocitySamples];
  }
  if (state.views.empty() && state.backdrops.empty()) {
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

bool settleFlightHost(
    uint64_t driverId,
    Presentation rest,
    Presentation &landed) {
  NSCAssert(NSThread.isMainThread, @"SmoothClip registry is main-thread only");
  if (!canonicalizePresentation(rest)) return false;
  auto iterator = registry().find(driverId);
  if (iterator == registry().end() || iterator->second.destroyed ||
      iterator->second.animation.has_value()) {
    return false;
  }
  DriverState &state = iterator->second;
  landed = state.latest;
  applyPresentation(state, rest, false);
  // No finger made this jump, and the frames before the flight no longer
  // describe the host: a later 'inherit' starts from nothing (as Android).
  for (const ViewKey key : state.views) {
    [viewForKey(key) smoothClipClearVelocitySamples];
  }
  return true;
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
  if (!applicationActiveState() || state.animation->exposedToInactivity) {
    state.animation->needsForegroundReconciliation = true;
    return;
  }
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
