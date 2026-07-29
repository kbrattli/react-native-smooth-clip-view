#import <XCTest/XCTest.h>

#import "SmoothClipView.h"
#import "SmoothClipViewRegistry.h"

#import <QuartzCore/QuartzCore.h>
#import <react/renderer/core/LayoutMetrics.h>

#include <cmath>
#include <unistd.h>

@interface SmoothClipRegistryTests : XCTestCase
@end

@implementation SmoothClipRegistryTests

static smoothclip::Presentation Presentation(
    double x,
    double y,
    double width,
    double height,
    double radius,
    double translateX = 0,
    double translateY = 0) {
  return {{x, y, width, height, radius}, translateX, translateY};
}

// A view that can actually produce a frame: laid out AND attached to a
// window. Since the displayability gate, latches only start (and CA installs
// only happen) for such views — a mount-time registration from a detached
// subtree holds the latch until window attach.
static SmoothClipView *DisplayableView(UIWindow *window, CGRect frame) {
  SmoothClipView *view = [[SmoothClipView alloc] initWithFrame:frame];
  facebook::react::LayoutMetrics metrics;
  metrics.frame = facebook::react::Rect{
      facebook::react::Point{frame.origin.x, frame.origin.y},
      facebook::react::Size{frame.size.width, frame.size.height}};
  [view updateLayoutMetrics:metrics
           oldLayoutMetrics:facebook::react::LayoutMetrics{}];
  [window addSubview:view];
  return view;
}

static UIWindow *TestWindow(void) {
  return [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 400, 800)];
}

- (void)testRegistrationIsIdempotentAndCleanupMatchesTheExactView {
  constexpr uint64_t driverId = 9001;
  SmoothClipView *first = [[SmoothClipView alloc] initWithFrame:CGRectZero];
  SmoothClipView *replacement =
      [[SmoothClipView alloc] initWithFrame:CGRectZero];
  const smoothclip::Presentation initial =
      Presentation(0, 0, 100, 100, 12, -4, -8);

  smoothclip::registerView(driverId, first, initial);
  smoothclip::registerView(driverId, first, initial);
  smoothclip::registerView(driverId, replacement, initial);
  XCTAssertEqual(smoothclip::registeredViewCount(driverId), 2u);

  smoothclip::unregisterView(driverId, first);
  XCTAssertEqual(smoothclip::registeredViewCount(driverId), 1u);
  smoothclip::unregisterView(driverId, first);
  XCTAssertEqual(smoothclip::registeredViewCount(driverId), 1u);
  smoothclip::unregisterView(driverId, replacement);
  XCTAssertEqual(smoothclip::registeredViewCount(driverId), 0u);
  smoothclip::destroyDriver(driverId);
}

// Unmounting the last rendering host mid-flight must NOT complete the
// animation at the target (the pre-fix behavior statically snapped any
// re-registering host to it). The remaining animation re-latches and a new
// host resumes it; only destroyDriver delivers the unfinished completion.
- (void)testUnmountRelatchesARegisteredTransition {
  constexpr uint64_t driverId = 9002;
  int completionCount = 0;
  BOOL completedFinished = YES;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver, int32_t animationId, bool finished) {
        if (completedDriver != driverId) return;
        completionCount += 1;
        completedFinished = finished;
      });
  UIWindow *window = TestWindow();
  SmoothClipView *view =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  smoothclip::registerView(driverId, view, initial);
  const int32_t animationId = smoothclip::animateTiming(
      driverId, {true, initial}, target, timing);
  XCTAssertGreaterThan(animationId, 0);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));

  smoothclip::unregisterView(driverId, view);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  XCTAssertEqual(completionCount, 0);

  // A new displayable host resumes the re-latched remainder.
  SmoothClipView *remounted =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  smoothclip::registerView(driverId, remounted, initial);
  UIView *container = [remounted valueForKey:@"clipContainer"];
  CAAnimationGroup *group = (CAAnimationGroup *)[container.layer
      animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(group);
  XCTAssertLessThanOrEqual(group.duration, 0.25 + 1e-3);
  XCTAssertGreaterThan(group.duration, 0);

  smoothclip::unregisterView(driverId, remounted);
  smoothclip::destroyDriver(driverId);
  XCTAssertEqual(completionCount, 1);
  XCTAssertFalse(completedFinished);
  smoothclip::clearCompletionCallback((__bridge const void *)self);
}

- (void)testBeginInteractionCancelsTheActiveTransitionAndReturnsCanonicalGeometry {
  constexpr uint64_t driverId = 9003;
  SmoothClipView *view = [[SmoothClipView alloc]
      initWithFrame:CGRectMake(0, 0, 120, 120)];
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  smoothclip::registerView(driverId, view, initial);
  smoothclip::animateTiming(driverId, {true, initial}, target, timing);
  const smoothclip::Presentation current =
      smoothclip::beginInteraction(driverId);

  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));
  XCTAssertTrue(std::isfinite(current.clip.width));
  XCTAssertTrue(std::isfinite(current.clip.height));
  XCTAssertTrue(std::isfinite(current.contentTranslateX));
  XCTAssertTrue(std::isfinite(current.contentTranslateY));
  smoothclip::unregisterView(driverId, view);
  smoothclip::destroyDriver(driverId);
}

// An animateTo issued before any host view registers must latch (held
// un-rendered) instead of instant-completing at the target — the pre-0.2.1
// behavior made a host that mounted one frame later jump straight to the
// target. The driver entry is created by the hook's authoritative seed, which
// setPresentation(takeOwnership) mirrors here.
- (void)testAnimateWithoutViewsLatchesUntilFirstRegistration {
  constexpr uint64_t driverId = 9004;
  int completionCount = 0;
  int32_t completedAnimation = 0;
  BOOL completedFinished = YES;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver, int32_t animationId, bool finished) {
        if (completedDriver != driverId) return;
        completionCount += 1;
        completedAnimation = animationId;
        completedFinished = finished;
      });
  UIWindow *window = TestWindow();
  SmoothClipView *view =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  smoothclip::setPresentation(driverId, initial, true);
  const int32_t animationId = smoothclip::animateTiming(
      driverId, {true, initial}, target, timing);
  XCTAssertGreaterThan(animationId, 0);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  XCTAssertEqual(completionCount, 0);

  // First displayable registration starts the latch — the animation stays
  // active and still has not completed.
  smoothclip::registerView(driverId, view, initial);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  XCTAssertEqual(completionCount, 0);

  // Unmounting mid-flight re-latches the remainder instead of completing at
  // the target; the single unfinished completion arrives at destroy.
  smoothclip::unregisterView(driverId, view);
  XCTAssertEqual(completionCount, 0);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  smoothclip::destroyDriver(driverId);
  XCTAssertEqual(completionCount, 1);
  XCTAssertEqual(completedAnimation, animationId);
  XCTAssertFalse(completedFinished);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));
  smoothclip::clearCompletionCallback((__bridge const void *)self);
}

// A latched animation never rendered, so freezing it (cancel without target /
// beginInteraction) must return its start — state.latest already holds the
// target, and freezing there would jump the clip.
- (void)testCancelingALatchedAnimationFreezesAtItsStart {
  constexpr uint64_t driverId = 9014;
  int completionCount = 0;
  BOOL completedFinished = YES;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver, int32_t animationId, bool finished) {
        if (completedDriver != driverId) return;
        completionCount += 1;
        completedFinished = finished;
      });
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  smoothclip::setPresentation(driverId, initial, true);
  smoothclip::animateTiming(driverId, {true, initial}, target, timing);
  const smoothclip::CancelResult cancel =
      smoothclip::cancelAnimation(driverId, 0, false);

  XCTAssertTrue(cancel.handled);
  XCTAssertEqual(cancel.presentation.clip.x, initial.clip.x);
  XCTAssertEqual(cancel.presentation.clip.width, initial.clip.width);
  XCTAssertEqual(
      cancel.presentation.contentTranslateX, initial.contentTranslateX);
  XCTAssertEqual(completionCount, 1);
  XCTAssertFalse(completedFinished);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));
  smoothclip::clearCompletionCallback((__bridge const void *)self);
  smoothclip::destroyDriver(driverId);
}

// The first registration rebases the latch clock: the installed transition
// must run its full duration, not the remainder measured from the pre-mount
// animateTo call.
- (void)testRegisterStartsLatchedAnimationFromItsStartWithFullDuration {
  constexpr uint64_t driverId = 9015;
  UIWindow *window = TestWindow();
  SmoothClipView *view =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  smoothclip::setPresentation(driverId, initial, true);
  const int32_t animationId = smoothclip::animateTiming(
      driverId, {true, initial}, target, timing);
  XCTAssertGreaterThan(animationId, 0);
  smoothclip::registerView(driverId, view, initial);

  UIView *container = [view valueForKey:@"clipContainer"];
  CAAnimationGroup *group = (CAAnimationGroup *)[container.layer
      animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(group);
  // Register happens microseconds after animateTiming; without the rebase the
  // remaining duration would already be visibly short of 250 ms.
  XCTAssertEqualWithAccuracy(group.duration, 0.25, 0.02);

  smoothclip::cancelAnimation(driverId, 0, false);
  smoothclip::unregisterView(driverId, view);
  smoothclip::destroyDriver(driverId);
}

// Replacing a latched animation (open then close before the host mounted)
// must cancel the first latch unfinished and start the second from the first
// latch's start — not from state.latest, which holds the first target.
- (void)testReplacingALatchedAnimationStartsFromTheLatchStart {
  constexpr uint64_t driverId = 9016;
  int completionCount = 0;
  int32_t lastCompleted = 0;
  BOOL lastFinished = YES;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver, int32_t animationId, bool finished) {
        if (completedDriver != driverId) return;
        completionCount += 1;
        lastCompleted = animationId;
        lastFinished = finished;
      });
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation targetA =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::Presentation targetB =
      Presentation(2, 2, 60, 60, 8, -1, -2);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  smoothclip::setPresentation(driverId, initial, true);
  const int32_t first = smoothclip::animateTiming(
      driverId, {true, initial}, targetA, timing);
  const int32_t second = smoothclip::animateTiming(
      driverId, {false, initial}, targetB, timing);
  XCTAssertGreaterThan(second, first);
  XCTAssertEqual(completionCount, 1);
  XCTAssertEqual(lastCompleted, first);
  XCTAssertFalse(lastFinished);

  // The replacement latched with the first latch's start; freezing proves it.
  const smoothclip::Presentation frozen =
      smoothclip::beginInteraction(driverId);
  XCTAssertEqual(frozen.clip.width, initial.clip.width);
  XCTAssertEqual(frozen.contentTranslateY, initial.contentTranslateY);
  XCTAssertEqual(completionCount, 2);
  XCTAssertEqual(lastCompleted, second);
  XCTAssertFalse(lastFinished);
  smoothclip::clearCompletionCallback((__bridge const void *)self);
  smoothclip::destroyDriver(driverId);
}

// A latch on a host that never mounts survives until the driver is destroyed
// and then delivers its single unfinished completion.
- (void)testDestroyDriverCancelsALatchedAnimation {
  constexpr uint64_t driverId = 9017;
  int completionCount = 0;
  BOOL completedFinished = YES;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver, int32_t animationId, bool finished) {
        if (completedDriver != driverId) return;
        completionCount += 1;
        completedFinished = finished;
      });
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  smoothclip::setPresentation(driverId, initial, true);
  smoothclip::animateTiming(driverId, {true, initial}, target, timing);
  XCTAssertEqual(completionCount, 0);

  smoothclip::destroyDriver(driverId);
  XCTAssertEqual(completionCount, 1);
  XCTAssertFalse(completedFinished);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));
  smoothclip::clearCompletionCallback((__bridge const void *)self);
}

- (void)testSevenScalarPresentationRoundTripsExactly {
  constexpr uint64_t driverId = 9005;
  SmoothClipView *view = [[SmoothClipView alloc]
      initWithFrame:CGRectMake(0, 0, 120, 120)];
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation updated =
      Presentation(0, 0, 80, 70, 14, -27, 19);
  smoothclip::registerView(driverId, view, initial);
  smoothclip::setPresentation(driverId, updated, true);
  const smoothclip::Presentation current =
      smoothclip::beginInteraction(driverId);
  XCTAssertEqual(current.clip.width, updated.clip.width);
  XCTAssertEqual(current.clip.height, updated.clip.height);
  XCTAssertEqual(current.contentTranslateX, updated.contentTranslateX);
  XCTAssertEqual(current.contentTranslateY, updated.contentTranslateY);
  smoothclip::unregisterView(driverId, view);
  smoothclip::destroyDriver(driverId);
}

- (void)testDestroyDriverCancelsAndErasesState {
  constexpr uint64_t driverId = 9006;
  SmoothClipView *view = [[SmoothClipView alloc]
      initWithFrame:CGRectMake(0, 0, 120, 120)];
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};
  smoothclip::registerView(driverId, view, initial);
  smoothclip::animateTiming(driverId, {true, initial}, target, timing);

  smoothclip::destroyDriver(driverId);

  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));
  // The view is still registered, so destroy keeps a tombstone; the entry
  // is erased when the last view leaves.
  XCTAssertEqual(smoothclip::registeredViewCount(driverId), 1u);
  smoothclip::unregisterView(driverId, view);
  XCTAssertEqual(smoothclip::registeredViewCount(driverId), 0u);
}

- (void)testJoinActiveAnimationReplaysForDeferredView {
  constexpr uint64_t driverId = 9007;
  UIWindow *window = TestWindow();
  SmoothClipView *canonical =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  SmoothClipView *deferred = [[SmoothClipView alloc] initWithFrame:CGRectZero];
  SmoothClipView *stray = [[SmoothClipView alloc] initWithFrame:CGRectZero];
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  smoothclip::registerView(driverId, canonical, initial);
  smoothclip::animateTiming(driverId, {true, initial}, target, timing);
  smoothclip::registerView(driverId, deferred, initial);

  XCTAssertTrue(smoothclip::joinActiveAnimation(driverId, deferred));
  XCTAssertFalse(smoothclip::joinActiveAnimation(driverId, stray));

  smoothclip::cancelAnimation(driverId, 0, false);
  XCTAssertFalse(smoothclip::joinActiveAnimation(driverId, deferred));
  smoothclip::unregisterView(driverId, canonical);
  smoothclip::unregisterView(driverId, deferred);
  smoothclip::destroyDriver(driverId);
  XCTAssertFalse(smoothclip::joinActiveAnimation(driverId, deferred));
}

- (void)testInteractionAfterLastUnregisterFreesTheRelatchedAnimation {
  constexpr uint64_t driverId = 9008;
  UIWindow *window = TestWindow();
  SmoothClipView *view =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::Presentation dragged = Presentation(4, 4, 60, 60, 10, 1, 2);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  smoothclip::registerView(driverId, view, initial);
  smoothclip::animateTiming(driverId, {true, initial}, target, timing);
  smoothclip::unregisterView(driverId, view);

  // The remainder re-latched (ownership stays Native — the pending animation
  // owns rendering intent), so a bare interactive delivery is dropped…
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  smoothclip::setPresentation(driverId, dragged, false);
  // …and the interactive flow goes through beginInteraction, exactly as it
  // would against a running animation: it frees the latch at a finite frozen
  // geometry and releases ownership.
  const smoothclip::Presentation frozen =
      smoothclip::beginInteraction(driverId);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));
  XCTAssertTrue(std::isfinite(frozen.clip.width));
  smoothclip::setPresentation(driverId, dragged, false);
  const smoothclip::Presentation current =
      smoothclip::beginInteraction(driverId);
  XCTAssertEqual(current.clip.x, dragged.clip.x);
  XCTAssertEqual(current.clip.width, dragged.clip.width);
  smoothclip::destroyDriver(driverId);
}

- (void)testDestroyKeepsATombstoneWhileViewsRemainRegistered {
  constexpr uint64_t driverId = 9009;
  SmoothClipView *view = [[SmoothClipView alloc] initWithFrame:CGRectZero];
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation stale = Presentation(1, 1, 50, 50, 9, 0, 0);
  const smoothclip::Presentation revived = Presentation(2, 2, 70, 70, 7, 0, 0);

  smoothclip::registerView(driverId, view, initial);
  smoothclip::destroyDriver(driverId);
  XCTAssertEqual(smoothclip::registeredViewCount(driverId), 1u);

  // Stale non-owning deliveries are dropped on the tombstone...
  smoothclip::setPresentation(driverId, stale, false);
  // ...but the hook's authoritative re-seed revives it.
  smoothclip::setPresentation(driverId, revived, true);
  const smoothclip::Presentation current =
      smoothclip::beginInteraction(driverId);
  XCTAssertEqual(current.clip.x, revived.clip.x);

  smoothclip::unregisterView(driverId, view);
  smoothclip::destroyDriver(driverId);
  XCTAssertEqual(smoothclip::registeredViewCount(driverId), 0u);
}

- (void)testDestroyedDriverEntryPointsFailDefinedAndDoNotResurrect {
  constexpr uint64_t driverId = 9012;
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};
  SmoothClipView *view = [[SmoothClipView alloc] initWithFrame:CGRectZero];
  smoothclip::registerView(driverId, view, initial);
  smoothclip::unregisterView(driverId, view);
  smoothclip::destroyDriver(driverId);

  XCTAssertEqual(
      smoothclip::animateTiming(driverId, {true, initial}, target, timing), 0);
  XCTAssertEqual(smoothclip::rejectAnimation(driverId), 0);
  XCTAssertFalse(
      std::isfinite(smoothclip::beginInteraction(driverId).clip.width));
  smoothclip::setPresentation(driverId, target, false);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));
  XCTAssertEqual(smoothclip::registeredViewCount(driverId), 0u);
}

- (void)testOffMainCallsFailDefinedWithoutBlocking {
  constexpr uint64_t driverId = 9010;
  SmoothClipView *view = [[SmoothClipView alloc]
      initWithFrame:CGRectMake(0, 0, 120, 120)];
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};
  smoothclip::registerView(driverId, view, initial);

  __block int32_t animationId = -1;
  __block int32_t rejected = -1;
  __block smoothclip::Presentation began = initial;
  __block smoothclip::CancelResult cancel{true, initial};
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  dispatch_async(
      dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        began = smoothclip::beginInteraction(driverId);
        animationId = smoothclip::animateTiming(
            driverId, {true, initial}, target, timing);
        cancel = smoothclip::cancelAnimation(driverId, 0, false);
        rejected = smoothclip::rejectAnimation(driverId);
        dispatch_semaphore_signal(done);
      });
  const long timedOut = dispatch_semaphore_wait(
      done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));

  // The off-main path must fail defined instead of blocking (a synchronous
  // main-queue hop can deadlock against the worklets UI-runtime mutex).
  XCTAssertEqual(timedOut, 0);
  XCTAssertFalse(std::isfinite(began.clip.width));
  XCTAssertEqual(animationId, 0);
  XCTAssertFalse(cancel.handled);
  XCTAssertEqual(rejected, 0);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));
  smoothclip::unregisterView(driverId, view);
  smoothclip::destroyDriver(driverId);
}

- (void)testSpringInitialVelocityIsPassedNormalizedToEveryKeyPath {
  constexpr uint64_t driverId = 9011;
  UIWindow *window = TestWindow();
  SmoothClipView *view =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  const smoothclip::Presentation initial = Presentation(0, 0, 40, 40, 8, 0, 0);
  smoothclip::registerView(driverId, view, initial);

  // reduceMotion 'never' so the spring installs even on CI machines.
  const smoothclip::SpringAnimation spring{1, 180, 18, 3.5, false, 2};
  const int32_t animationId = smoothclip::animateSpring(
      driverId, {true, initial},
      Presentation(0, 0, 100, 100, 12, -20, -30), spring);
  XCTAssertGreaterThan(animationId, 0);

  // CASpringAnimation.initialVelocity is normalized (its settlingDuration is
  // independent of the from/to distance), so the projected scalar must reach
  // every key path unchanged — not multiplied by per-property deltas.
  UIView *container = [view valueForKey:@"clipContainer"];
  CAAnimationGroup *group = (CAAnimationGroup *)[container.layer
      animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(group);
  XCTAssertEqual(group.animations.count, 7u);
  for (CASpringAnimation *animation in group.animations) {
    XCTAssertEqualWithAccuracy(animation.initialVelocity, 3.5, 1e-9);
    // One settling solve is shared by the whole group; every spring's assigned
    // duration must still equal its own settlingDuration.
    XCTAssertEqualWithAccuracy(animation.duration, group.duration, 1e-6);
    XCTAssertEqualWithAccuracy(
        animation.duration, animation.settlingDuration, 1e-6);
  }

  smoothclip::cancelAnimation(driverId, 0, false);
  smoothclip::unregisterView(driverId, view);
  smoothclip::destroyDriver(driverId);
}

- (void)testNonOwningDeliveryNeverCreatesADriverEntry {
  constexpr uint64_t driverId = 9013;
  smoothclip::setPresentation(
      driverId, Presentation(1, 2, 30, 40, 5, 0, 0), false);
  XCTAssertEqual(smoothclip::registeredViewCount(driverId), 0u);
  XCTAssertFalse(
      std::isfinite(smoothclip::beginInteraction(driverId).clip.width));
}

// A CA animation committed while the host's layer tree is detached (a
// transparentModal subtree before UIKit presents its view controller) is
// removed at the attach commit with finished=NO, snapping the layer to the
// model values — the target. The latch therefore must stay held for a
// registered-but-detached view and start inside the window-attach commit
// with its full duration (the northernLights_new map-overlay bug).
- (void)testLatchHeldForDetachedViewStartsAtWindowAttach {
  constexpr uint64_t driverId = 9018;
  SmoothClipView *view = [[SmoothClipView alloc]
      initWithFrame:CGRectMake(0, 0, 120, 120)];
  facebook::react::LayoutMetrics metrics;
  metrics.frame = facebook::react::Rect{
      facebook::react::Point{0, 0}, facebook::react::Size{120, 120}};
  [view updateLayoutMetrics:metrics
           oldLayoutMetrics:facebook::react::LayoutMetrics{}];
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  smoothclip::setPresentation(driverId, initial, true);
  smoothclip::animateTiming(driverId, {true, initial}, target, timing);
  // Production sets the driverId ivar in updateProps before registering;
  // didMoveToWindow's registry call is gated on it, so mirror that here.
  [view setValue:@(driverId) forKey:@"driverId"];
  // Laid out but not in a window: registration must keep the latch held and
  // must not install any CA animation.
  smoothclip::registerView(driverId, view, initial);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  UIView *container = [view valueForKey:@"clipContainer"];
  XCTAssertNil([container.layer animationForKey:@"smoothClip.geometry"]);

  // Window attach (didMoveToWindow → viewBecameDisplayable) starts the latch
  // with the full duration, inside the attach commit.
  UIWindow *window = TestWindow();
  [window addSubview:view];
  CAAnimationGroup *group = (CAAnimationGroup *)[container.layer
      animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(group);
  XCTAssertEqualWithAccuracy(group.duration, 0.25, 0.02);

  smoothclip::cancelAnimation(driverId, 0, false);
  smoothclip::unregisterView(driverId, view);
  smoothclip::destroyDriver(driverId);
}

// Reduce Motion is honored BEFORE the latch: an animateTo with no views and
// reduceMotion=always instant-completes at the target with finished:true.
// This is deliberate platform behavior (documented), not the latch bug.
- (void)testReduceMotionInstantCompletesBeforeTheLatch {
  constexpr uint64_t driverId = 9019;
  int completionCount = 0;
  BOOL completedFinished = NO;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver, int32_t animationId, bool finished) {
        if (completedDriver != driverId) return;
        completionCount += 1;
        completedFinished = finished;
      });
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  // reduceMotion 1 == always.
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 1};

  smoothclip::setPresentation(driverId, initial, true);
  const int32_t animationId = smoothclip::animateTiming(
      driverId, {true, initial}, target, timing);
  XCTAssertGreaterThan(animationId, 0);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));
  XCTAssertEqual(completionCount, 1);
  XCTAssertTrue(completedFinished);
  const smoothclip::Presentation current =
      smoothclip::beginInteraction(driverId);
  XCTAssertEqual(current.clip.width, target.clip.width);
  smoothclip::clearCompletionCallback((__bridge const void *)self);
  smoothclip::destroyDriver(driverId);
}

// The hook's take-ownership seed replays a SharedValue an earlier animateTo
// already advanced to its target. A held latch is strictly newer intent, so
// the seed must not cancel it (that would seed the target and turn the
// pending animation into a static jump).
- (void)testTakeOwnershipSeedDoesNotCancelAHeldLatch {
  constexpr uint64_t driverId = 9020;
  int completionCount = 0;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver, int32_t animationId, bool finished) {
        if (completedDriver != driverId) return;
        completionCount += 1;
      });
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  smoothclip::setPresentation(driverId, initial, true);
  smoothclip::animateTiming(driverId, {true, initial}, target, timing);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));

  // A replayed seed carrying the (stale) target value must be a no-op.
  smoothclip::setPresentation(driverId, target, true);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  XCTAssertEqual(completionCount, 0);

  // The latch still resumes from its own start on the first displayable host.
  UIWindow *window = TestWindow();
  SmoothClipView *view =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  smoothclip::registerView(driverId, view, initial);
  UIView *container = [view valueForKey:@"clipContainer"];
  XCTAssertNotNil([container.layer animationForKey:@"smoothClip.geometry"]);

  smoothclip::cancelAnimation(driverId, 0, false);
  smoothclip::unregisterView(driverId, view);
  smoothclip::clearCompletionCallback((__bridge const void *)self);
  smoothclip::destroyDriver(driverId);
}

// beginInteraction while a registered-but-unlaid-out peer exists must not
// adopt that peer's {0,0,0,0} as the canonical frozen geometry.
- (void)testFrozenPresentationSkipsUnlaidOutViews {
  constexpr uint64_t driverId = 9021;
  UIWindow *window = TestWindow();
  SmoothClipView *laidOut =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  SmoothClipView *unlaidOut =
      [[SmoothClipView alloc] initWithFrame:CGRectZero];
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  // The unlaid-out peer registers first so it is the first freeze candidate;
  // the joinable filter must skip past it to the laid-out view.
  smoothclip::registerView(driverId, unlaidOut, initial);
  smoothclip::registerView(driverId, laidOut, initial);
  smoothclip::animateTiming(driverId, {true, initial}, target, timing);
  const smoothclip::Presentation frozen =
      smoothclip::beginInteraction(driverId);

  XCTAssertGreaterThan(frozen.clip.width, 0.0);
  XCTAssertGreaterThan(frozen.clip.height, 0.0);
  smoothclip::unregisterView(driverId, laidOut);
  smoothclip::unregisterView(driverId, unlaidOut);
  smoothclip::destroyDriver(driverId);
}

// A view that joins a running animation while it cannot display defers its
// install; window attach completes it through the registry join on the
// ORIGINAL clock, so late joiners stay in sync with already-visible peers.
- (void)testDeferredInstallCompletesAtWindowAttach {
  constexpr uint64_t driverId = 9022;
  UIWindow *window = TestWindow();
  SmoothClipView *displayable =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  SmoothClipView *deferred = [[SmoothClipView alloc]
      initWithFrame:CGRectMake(0, 0, 120, 120)];
  facebook::react::LayoutMetrics metrics;
  metrics.frame = facebook::react::Rect{
      facebook::react::Point{0, 0}, facebook::react::Size{120, 120}};
  [deferred updateLayoutMetrics:metrics
               oldLayoutMetrics:facebook::react::LayoutMetrics{}];
  [deferred setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  smoothclip::registerView(driverId, displayable, initial);
  smoothclip::registerView(driverId, deferred, initial);
  smoothclip::animateTiming(driverId, {true, initial}, target, timing);

  // The displayable peer installed immediately; the detached one deferred.
  UIView *peerContainer = [displayable valueForKey:@"clipContainer"];
  UIView *container = [deferred valueForKey:@"clipContainer"];
  XCTAssertNotNil(
      [peerContainer.layer animationForKey:@"smoothClip.geometry"]);
  XCTAssertNil([container.layer animationForKey:@"smoothClip.geometry"]);

  // Window attach (didMoveToWindow → viewBecameDisplayable) completes the
  // deferred install with the animation's remaining time.
  [window addSubview:deferred];
  CAAnimationGroup *group = (CAAnimationGroup *)[container.layer
      animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(group);
  XCTAssertGreaterThan(group.duration, 0);
  XCTAssertLessThanOrEqual(group.duration, 0.25 + 1e-3);

  smoothclip::cancelAnimation(driverId, 0, false);
  smoothclip::unregisterView(driverId, displayable);
  smoothclip::unregisterView(driverId, deferred);
  smoothclip::destroyDriver(driverId);
}

// A second layout pass while still detached (safe-area propagation inside an
// un-presented transparentModal subtree) must NOT install: a CA animation
// committed from a detached layer tree dies at the attach commit. The
// deferral is kept and window attach completes it.
- (void)testDetachedRelayoutKeepsTheDeferredInstall {
  constexpr uint64_t driverId = 9023;
  UIWindow *window = TestWindow();
  SmoothClipView *displayable =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  SmoothClipView *deferred = [[SmoothClipView alloc]
      initWithFrame:CGRectMake(0, 0, 120, 120)];
  facebook::react::LayoutMetrics metrics;
  metrics.frame = facebook::react::Rect{
      facebook::react::Point{0, 0}, facebook::react::Size{120, 120}};
  [deferred updateLayoutMetrics:metrics
               oldLayoutMetrics:facebook::react::LayoutMetrics{}];
  [deferred setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  smoothclip::registerView(driverId, displayable, initial);
  smoothclip::registerView(driverId, deferred, initial);
  smoothclip::animateTiming(driverId, {true, initial}, target, timing);
  UIView *container = [deferred valueForKey:@"clipContainer"];
  XCTAssertNil([container.layer animationForKey:@"smoothClip.geometry"]);

  // Second layout while detached: the install must stay deferred.
  facebook::react::LayoutMetrics resized;
  resized.frame = facebook::react::Rect{
      facebook::react::Point{0, 0}, facebook::react::Size{140, 140}};
  [deferred updateLayoutMetrics:resized oldLayoutMetrics:metrics];
  XCTAssertNil([container.layer animationForKey:@"smoothClip.geometry"]);

  // The deferral survived, so the attach still completes the install.
  [window addSubview:deferred];
  XCTAssertNotNil([container.layer animationForKey:@"smoothClip.geometry"]);

  smoothclip::cancelAnimation(driverId, 0, false);
  smoothclip::unregisterView(driverId, displayable);
  smoothclip::unregisterView(driverId, deferred);
  smoothclip::destroyDriver(driverId);
}

// The fused animateTo `from` handoff desugars to a take-ownership write
// issued sub-millisecond after the last drag write. The velocity tracker
// coalesces that same-frame pair, so an inherited spring launches with an
// honest, bounded initialVelocity — not zero (identical seed) and not the
// sub-frame displacement divided by microseconds (distinct seed).
- (void)testSeededSpringHandoffInstallsBoundedInitialVelocity {
  constexpr uint64_t driverId = 9017;
  UIWindow *window = TestWindow();
  SmoothClipView *view =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  const smoothclip::Presentation initial = Presentation(0, 0, 40, 40, 8, 0, 0);
  smoothclip::registerView(driverId, view, initial);

  // Drag frame, one real frame apart, then the release seed in the same
  // input batch (exactly what animateTo's `from` fusion issues).
  smoothclip::setPresentation(driverId, Presentation(0, 1, 40, 40, 8), true);
  usleep(16000);
  smoothclip::setPresentation(driverId, Presentation(0, 4, 40, 40, 8), true);
  smoothclip::setPresentation(driverId, Presentation(0, 5, 40, 40, 8), true);

  // reduceMotion 'never' so the spring installs even on CI machines;
  // inheritVelocity = true.
  const smoothclip::SpringAnimation spring{1, 180, 18, 0, true, 2};
  const int32_t animationId = smoothclip::animateSpring(
      driverId, {false, initial},
      Presentation(0, 0, 100, 100, 12, -20, -30), spring);
  XCTAssertGreaterThan(animationId, 0);

  UIView *container = [view valueForKey:@"clipContainer"];
  CAAnimationGroup *group = (CAAnimationGroup *)[container.layer
      animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(group);
  XCTAssertEqual(group.animations.count, 7u);
  // Honest bound: 4-5 DIP of drag over >= 16 ms projected onto a remaining
  // distance of ~115 DIP is well under 1 in normalized units. The pre-fix
  // rotation measured 1 DIP over the sub-millisecond seed gap instead —
  // tens of units. Every key path carries the same scalar.
  const double first =
      ((CASpringAnimation *)group.animations.firstObject).initialVelocity;
  for (CASpringAnimation *animation in group.animations) {
    XCTAssertTrue(std::isfinite(animation.initialVelocity));
    XCTAssertEqualWithAccuracy(animation.initialVelocity, first, 1e-9);
    XCTAssertLessThan(std::fabs(animation.initialVelocity), 1.0);
  }

  smoothclip::cancelAnimation(driverId, 0, false);
  smoothclip::unregisterView(driverId, view);
  smoothclip::destroyDriver(driverId);
}

@end
