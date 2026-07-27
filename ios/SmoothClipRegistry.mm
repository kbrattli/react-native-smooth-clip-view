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

@interface SmoothClipView (Registry)
- (void)smoothClipApplyPresentation:(smoothclip::Presentation)presentation;
- (smoothclip::Presentation)smoothClipFreezePresentation;
- (smoothclip::Presentation)smoothClipCurrentPresentation;
- (void)smoothClipAnimateTiming:(smoothclip::Presentation)presentation
                       animation:(smoothclip::TimingAnimation)animation
                     animationId:(int32_t)animationId;
- (void)smoothClipAnimateSpring:(smoothclip::Presentation)presentation
                       animation:(smoothclip::SpringAnimation)animation
                     animationId:(int32_t)animationId;
- (void)smoothClipAnimateKeyframes:(smoothclip::Presentation)presentation
                         keyframes:(const std::vector<smoothclip::Keyframe> &)keyframes
                         durationMs:(double)durationMs
                        animationId:(int32_t)animationId;
- (void)smoothClipCancelAnimationUsingTarget:(BOOL)useTarget;
- (BOOL)smoothClipIsJoinable;
@end

namespace smoothclip {
namespace {

using ViewKey = uintptr_t;

enum class Ownership { Interactive, Native };
enum class AnimationKind { Timing, Spring, Keyframes };

struct ActiveAnimation {
  int32_t animationId;
  std::unordered_set<ViewKey> participants;
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
};

struct DriverState {
  Presentation latest{{0, 0, 0, 0, 0}, 0, 0};
  bool hasLatest = false;
  Ownership ownership = Ownership::Interactive;
  std::vector<ViewKey> views;
  std::optional<ActiveAnimation> animation;
  int32_t nextAnimationId = 0;
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

int32_t allocateAnimationId(DriverState &state) {
  state.nextAnimationId =
      state.nextAnimationId == std::numeric_limits<int32_t>::max()
      ? 1
      : state.nextAnimationId + 1;
  return state.nextAnimationId;
}

Presentation canonicalFrozenPresentation(DriverState &state) {
  Presentation canonical = state.latest;
  bool hasCanonical = false;
  for (const ViewKey key : state.views) {
    const Presentation frozen = [viewForKey(key) smoothClipFreezePresentation];
    if (!hasCanonical) {
      canonical = frozen;
      hasCanonical = true;
    }
  }
  return canonical;
}

void cancelActive(
    uint64_t driverId,
    DriverState &state,
    bool useTarget) {
  if (!state.animation.has_value()) return;
  const int32_t animationId = state.animation->animationId;
  for (const ViewKey key : state.animation->participants) {
    [viewForKey(key) smoothClipCancelAnimationUsingTarget:useTarget];
  }
  emitCompletion(driverId, state, animationId, false);
}

void applyPresentation(DriverState &state, Presentation presentation) {
  state.latest = presentation;
  state.hasLatest = true;
  state.ownership = Ownership::Interactive;
  for (const ViewKey key : state.views) {
    [viewForKey(key) smoothClipApplyPresentation:presentation];
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
  return start.hasInteractiveStart && state.ownership == Ownership::Interactive
      ? start.interactiveStart
      : state.latest;
}

// Installs the remaining part of the active animation on a view that joins
// mid-flight, starting from `visible`. Shared by registerView (mount during
// animation) and joinActiveAnimation (first layout after such a mount).
void dispatchActiveAnimationJoin(
    DriverState &state,
    SmoothClipView *view,
    ViewKey key,
    const Presentation &visible) {
  auto &active = *state.animation;
  active.participants.insert(key);
  const double elapsedMs = (CACurrentMediaTime() - active.startedAt) * 1000.0;
  const double remainingMs = MAX(0, active.durationMs - elapsedMs);
  if (active.kind == AnimationKind::Timing) {
    TimingAnimation timing = active.timing;
    timing.durationMs = remainingMs;
    [view smoothClipAnimateTiming:state.latest
                        animation:timing
                      animationId:active.animationId];
  } else if (active.kind == AnimationKind::Spring) {
    [view smoothClipAnimateSpring:state.latest
                        animation:active.spring
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
    [view smoothClipAnimateKeyframes:state.latest
                           keyframes:remaining
                          durationMs:remainingMs
                         animationId:active.animationId];
  }
}

} // namespace

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
  const bool shouldReplay =
      state.animation.has_value() && !state.views.empty();
  Presentation visible = state.latest;
  if (shouldReplay) {
    // A registered peer that never laid out reports zero geometry; joining
    // from it would visibly collapse the clip. Prefer the first laid-out
    // peer and fall back to the animation's start.
    SmoothClipView *reference = nil;
    for (const ViewKey candidate : state.views) {
      SmoothClipView *candidateView = viewForKey(candidate);
      if ([candidateView smoothClipIsJoinable]) {
        reference = candidateView;
        break;
      }
    }
    visible = reference != nil
        ? [reference smoothClipCurrentPresentation]
        : state.animation->start;
  }
  const ViewKey key = keyForView(view);
  if (std::find(state.views.begin(), state.views.end(), key) ==
      state.views.end()) {
    state.views.push_back(key);
  }
  [view smoothClipApplyPresentation:visible];
  if (!shouldReplay || !state.animation.has_value()) return;

  dispatchActiveAnimationJoin(state, view, key, visible);
}

bool joinActiveAnimation(uint64_t driverId, SmoothClipView *view) {
  NSCAssert(NSThread.isMainThread, @"SmoothClip registry is main-thread only");
  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return false;
  auto &state = iterator->second;
  if (!state.animation.has_value() || state.views.empty()) return false;
  const ViewKey key = keyForView(view);
  if (std::find(state.views.begin(), state.views.end(), key) ==
      state.views.end()) {
    return false;
  }
  // Join from a laid-out peer's live presentation, exactly as a view that had
  // registered at this moment would. When the joining view is the only
  // registered host, its own layer never received geometry (the install was
  // deferred for lack of layout), so fall back to the animation's start.
  ViewKey canonicalKey = 0;
  for (const ViewKey candidate : state.views) {
    if (candidate != key && [viewForKey(candidate) smoothClipIsJoinable]) {
      canonicalKey = candidate;
      break;
    }
  }
  const Presentation visible = canonicalKey != 0
      ? [viewForKey(canonicalKey) smoothClipCurrentPresentation]
      : state.animation->start;
  [view smoothClipApplyPresentation:visible];
  dispatchActiveAnimationJoin(state, view, key, visible);
  return true;
}

void unregisterView(uint64_t driverId, SmoothClipView *view) {
  NSCAssert(NSThread.isMainThread, @"SmoothClip registry is main-thread only");
  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return;

  auto &state = iterator->second;
  const ViewKey key = keyForView(view);
  if (state.animation.has_value() &&
      state.animation->participants.erase(key) > 0) {
    state.animation->finished = false;
    if (state.animation->participants.empty()) {
      // The animation ends here; without releasing ownership a host that
      // remounts on this driver later would drop every interactive update.
      state.ownership = Ownership::Interactive;
      emitCompletion(
          driverId, state, state.animation->animationId, false);
    }
  }
  state.views.erase(
      std::remove(state.views.begin(), state.views.end(), key),
      state.views.end());
  if (state.destroyed && state.views.empty()) {
    registry().erase(iterator);
  }
}

void setPresentation(
    uint64_t driverId,
    Presentation presentation,
    bool takeOwnership) {
  // CALayer writes require the main thread (not main-queue drain context).
  if (!NSThread.isMainThread) {
    // Never block an off-main caller: a synchronous hop can deadlock against
    // the worklets UI-runtime mutex (runOnUISync executes on the calling
    // thread while holding it, and the main thread routinely waits for the
    // same mutex when draining scheduled worklets).
    RCTExecuteOnMainQueue(^{
      setPresentation(driverId, presentation, takeOwnership);
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
  }  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return 0;
  auto &state = iterator->second;
  state.destroyed = false;
  const int32_t animationId = allocateAnimationId(state);
  const Presentation resolvedStart = resolvedAnimationStart(state, start);
  prepareAnimation(driverId, state, start, presentation);

  if (shouldReduceMotion(animation.reduceMotion) || animation.durationMs <= 0) {
    applyPresentation(state, presentation);
    emitCompletion(driverId, state, animationId, true);
    return animationId;
  }

  ActiveAnimation active{animationId};
  active.kind = AnimationKind::Timing;
  active.start = resolvedStart;
  active.timing = animation;
  active.durationMs = animation.durationMs;
  active.startedAt = CACurrentMediaTime();
  active.participants.insert(state.views.begin(), state.views.end());
  state.animation = std::move(active);
  if (state.views.empty()) {
    state.ownership = Ownership::Interactive;
    emitCompletion(driverId, state, animationId, true);
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
    [viewForKey(key) smoothClipAnimateTiming:presentation
                                  animation:animation
                                animationId:animationId];
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
  }  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return 0;
  auto &state = iterator->second;
  state.destroyed = false;
  const int32_t animationId = allocateAnimationId(state);
  const Presentation resolvedStart = resolvedAnimationStart(state, start);
  prepareAnimation(driverId, state, start, presentation);

  if (shouldReduceMotion(animation.reduceMotion)) {
    applyPresentation(state, presentation);
    emitCompletion(driverId, state, animationId, true);
    return animationId;
  }

  ActiveAnimation active{animationId};
  active.kind = AnimationKind::Spring;
  active.start = resolvedStart;
  active.spring = animation;
  active.startedAt = CACurrentMediaTime();
  active.participants.insert(state.views.begin(), state.views.end());
  state.animation = std::move(active);
  if (state.views.empty()) {
    state.ownership = Ownership::Interactive;
    emitCompletion(driverId, state, animationId, true);
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
    [viewForKey(key) smoothClipAnimateSpring:presentation
                                  animation:animation
                                animationId:animationId];
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
  }  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return 0;
  auto &state = iterator->second;
  state.destroyed = false;
  const int32_t animationId = allocateAnimationId(state);
  const Presentation resolvedStart = resolvedAnimationStart(state, start);
  prepareAnimation(driverId, state, start, presentation);
  if (shouldReduceMotion(reduceMotion) || durationMs <= 0) {
    applyPresentation(state, presentation);
    emitCompletion(driverId, state, animationId, true);
    return animationId;
  }

  ActiveAnimation active{animationId};
  active.kind = AnimationKind::Keyframes;
  active.start = resolvedStart;
  active.keyframes = keyframes;
  active.durationMs = durationMs;
  active.startedAt = CACurrentMediaTime();
  active.participants.insert(state.views.begin(), state.views.end());
  state.animation = std::move(active);
  if (state.views.empty()) {
    state.ownership = Ownership::Interactive;
    emitCompletion(driverId, state, animationId, true);
    return animationId;
  }
  for (const ViewKey key : state.views) {
    [viewForKey(key) smoothClipAnimateKeyframes:presentation
                                      keyframes:keyframes
                                     durationMs:durationMs
                                    animationId:animationId];
  }
  return animationId;
}

int32_t rejectAnimation(uint64_t driverId) {
  if (!NSThread.isMainThread) {
    // See setPresentation: blocking off-main risks a deadlock.
    return 0;
  }  auto iterator = registry().find(driverId);
  if (iterator == registry().end()) return 0;
  const int32_t animationId = allocateAnimationId(iterator->second);
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
    cancelActive(driverId, state, true);
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

  const ViewKey key = keyForView(view);
  if (state.animation->participants.erase(key) == 0) return;
  state.animation->finished = state.animation->finished && finished;
  if (state.animation->participants.empty()) {
    state.ownership = Ownership::Interactive;
    emitCompletion(
        driverId, state, animationId, state.animation->finished);
  }
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
