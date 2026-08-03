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

@interface SmoothClipView (Registry)
- (void)smoothClipApplyPresentation:(smoothclip::Presentation)presentation;
- (void)smoothClipApplyPresentation:(smoothclip::Presentation)presentation
               recordVelocitySample:(BOOL)recordVelocitySample;
- (smoothclip::Presentation)smoothClipFreezePresentation;
- (smoothclip::Presentation)smoothClipCurrentPresentation;
- (BOOL)smoothClipAnimateTiming:(smoothclip::Presentation)presentation
                       animation:(smoothclip::TimingAnimation)animation
                     animationId:(int32_t)animationId;
- (BOOL)smoothClipAnimateSpring:(smoothclip::Presentation)presentation
                       animation:(smoothclip::SpringAnimation)animation
                     animationId:(int32_t)animationId;
- (BOOL)smoothClipAnimateKeyframes:(smoothclip::Presentation)presentation
                         keyframes:(const std::vector<smoothclip::Keyframe> &)keyframes
                         durationMs:(double)durationMs
                        animationId:(int32_t)animationId;
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

std::unordered_map<uint64_t, DriverState> &registry() {
  static std::unordered_map<uint64_t, DriverState> value;
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

// The sink is written from the TurboModule ctor/dtor on the JS thread and
// invoked on main. Invoking under the lock also keeps the owning module
// alive for the duration of the callback.
std::mutex &completionSinkMutex() {
  static std::mutex value;
  return value;
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

bool shouldReduceMotion(int32_t setting) {
  return setting == 1 ||
      (setting == 0 && UIAccessibilityIsReduceMotionEnabled());
}

void emitCompletion(
    uint64_t driverId,
    DriverState &state,
    int32_t animationId,
    bool finished) {
  state.animation.reset();
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

void cancelActive(
    uint64_t driverId,
    DriverState &state,
    bool useTarget) {
  if (!state.animation.has_value()) return;
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
  const bool acceptsInteractiveStart =
      start.hasInteractiveStart && state.ownership == Ownership::Interactive;
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
  if (start.hasInteractiveStart && state.ownership == Ownership::Interactive) {
    return start.interactiveStart;
  }
  // Replacing a latched animation (e.g. open→close before the host mounted):
  // it never rendered, and state.latest is its target — start from where the
  // clip actually is, the latch's own start.
  if (state.animation.has_value() && !state.animation->started) {
    return state.animation->start;
  }
  return state.latest;
}

// Installs the remaining part of the active animation on a view that joins
// mid-flight, starting from `visible`. Shared by registerView (mount during
// animation) and joinActiveAnimation (first layout after such a mount).
void dispatchActiveAnimationJoin(
    DriverState &state,
    SmoothClipView *view,
    ViewKey key,
    const Presentation &visible,
    SmoothClipView *reference = nil) {
  auto &active = *state.animation;
  const double elapsedMs = (CACurrentMediaTime() - active.startedAt) * 1000.0;
  const double remainingMs = MAX(0, active.durationMs - elapsedMs);
  BOOL installed = NO;
  if (active.kind == AnimationKind::Timing) {
    const double progress = active.durationMs <= 0
        ? 1
        : MIN(1, MAX(0, elapsedMs / active.durationMs));
    TimingAnimation timing = timingRemainder(active.timing, progress).animation;
    installed = [view smoothClipAnimateTiming:state.latest
                                    animation:timing
                                  animationId:active.animationId];
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
                                  animationId:active.animationId];
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
                                    animationId:active.animationId];
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

} // namespace

bool applicationIsActive() {
  return applicationActiveState();
}

void applicationWillResignActive() {
  NSCAssert(NSThread.isMainThread, @"SmoothClip registry is main-thread only");
  if (!applicationActiveState()) return;
  applicationActiveState() = false;
  for (auto &[driverId, state] : registry()) {
    relatchActiveAnimation(driverId, state);
  }
}

void applicationDidBecomeActive() {
  NSCAssert(NSThread.isMainThread, @"SmoothClip registry is main-thread only");
  if (applicationActiveState()) return;
  applicationActiveState() = true;
  for (auto &[driverId, state] : registry()) {
    (void)driverId;
    if (state.animation.has_value() && !state.animation->started &&
        anyDisplayableView(state)) {
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

void registerView(
    uint64_t driverId,
    SmoothClipView *view,
    Presentation initialPresentation) {
  NSCAssert(NSThread.isMainThread, @"SmoothClip registry is main-thread only");
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
    bool overridePendingAnimation) {
  // CALayer writes require the main thread (not main-queue drain context).
  if (!NSThread.isMainThread) {
    // Never block an off-main caller: a synchronous hop can deadlock against
    // the worklets UI-runtime mutex (runOnUISync executes on the calling
    // thread while holding it, and the main thread routinely waits for the
    // same mutex when draining scheduled worklets).
    RCTExecuteOnMainQueue(^{
      setPresentation(
          driverId, presentation, takeOwnership, overridePendingAnimation);
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
  applyPresentation(state, presentation);
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
  }  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return unavailablePresentation();
  auto &state = iterator->second;
  state.destroyed = false;
  if (!state.animation.has_value()) {
    state.ownership = Ownership::Interactive;
    return state.latest;
  }

  const int32_t animationId = state.animation->animationId;
  const Presentation canonical = canonicalFrozenPresentation(state);
  state.latest = canonical;
  state.hasLatest = true;
  state.ownership = Ownership::Interactive;
  emitCompletion(driverId, state, animationId, false);
  return canonical;
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
  const Presentation resolvedStart = resolvedAnimationStart(state, start);
  prepareAnimation(driverId, state, start, presentation);

  if (shouldReduceMotion(animation.reduceMotion) || animation.durationMs <= 0) {
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
  const Presentation resolvedStart = resolvedAnimationStart(state, start);
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
  const Presentation resolvedStart = resolvedAnimationStart(state, start);
  prepareAnimation(driverId, state, start, presentation);
  if (shouldReduceMotion(reduceMotion) || durationMs <= 0) {
    applyPresentation(state, presentation, false);
    emitCompletion(driverId, state, animationId, true);
    return animationId;
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
