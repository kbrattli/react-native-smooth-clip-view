#import <XCTest/XCTest.h>

#import "SmoothClipView.h"
#import "SmoothClipViewRegistry.h"

#import <QuartzCore/QuartzCore.h>
#import <react/renderer/components/SmoothClipViewSpec/Props.h>
#import <react/renderer/core/LayoutMetrics.h>

#include "SmoothClipAnimationCurve.h"

#include <cmath>
#include <unistd.h>

@interface SmoothClipView (SmoothClipRegistryTests)
- (double)smoothClipSpringContinuationVelocity;
- (smoothclip::Presentation)smoothClipCurrentPresentation;
- (void)setClipPresentationV2:(double)x
                            y:(double)y
                        width:(double)width
                       height:(double)height
                topLeftRadius:(double)topLeftRadius
               topRightRadius:(double)topRightRadius
            bottomRightRadius:(double)bottomRightRadius
             bottomLeftRadius:(double)bottomLeftRadius
                    curveCode:(NSInteger)curveCode
            contentTranslateX:(double)contentTranslateX
            contentTranslateY:(double)contentTranslateY
                 contentScale:(double)contentScale;
@end

@interface SmoothClipRegistryTests : XCTestCase
@end

@implementation SmoothClipRegistryTests

- (void)setUp {
  [super setUp];
  smoothclip::applicationDidBecomeActive();
}

- (void)tearDown {
  smoothclip::applicationDidBecomeActive();
  [super tearDown];
}

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

static smoothclip::Presentation PresentationV2(
    double x,
    double y,
    double width,
    double height,
    double topLeftRadius,
    double topRightRadius,
    double bottomRightRadius,
    double bottomLeftRadius,
    smoothclip::ClipCurve curve,
    double translateX,
    double translateY,
    double scale) {
  const bool uniform = topLeftRadius == topRightRadius &&
      topLeftRadius == bottomRightRadius &&
      topLeftRadius == bottomLeftRadius;
  smoothclip::Geometry geometry{
      x, y, width, height, uniform ? topLeftRadius : 0};
  geometry.topLeftRadius = topLeftRadius;
  geometry.topRightRadius = topRightRadius;
  geometry.bottomRightRadius = bottomRightRadius;
  geometry.bottomLeftRadius = bottomLeftRadius;
  geometry.curve = curve;
  return {geometry, translateX, translateY, scale};
}

static smoothclip::GroupMotionEntry GroupEntry(
    uint64_t driverId,
    bool hasFrom,
    smoothclip::Presentation from,
    smoothclip::Presentation target) {
  return {driverId, hasFrom, from, target, {}};
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

- (void)testFabricV2InitialPropsSeedEveryChannelAndRejectAtomically {
  constexpr uint64_t driverId = 99070;
  constexpr uint64_t rejectedDriverId = 99071;
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  auto initialProps =
      std::make_shared<facebook::react::SmoothClipViewProps>();
  initialProps->driverId = driverId;
  initialProps->presentationVersion = 2;
  initialProps->initialClipX = 10;
  initialProps->initialClipY = 20;
  initialProps->initialClipWidth = 120;
  initialProps->initialClipHeight = 80;
  // The legacy shorthand must not overwrite explicit V2 corners.
  initialProps->initialClipRadius = 99;
  initialProps->initialClipTopLeftRadius = 32;
  initialProps->initialClipTopRightRadius = 20;
  initialProps->initialClipBottomRightRadius = 12;
  initialProps->initialClipBottomLeftRadius = 4;
  initialProps->initialClipCurve =
      static_cast<int>(smoothclip::ClipCurve::Continuous);
  initialProps->initialContentTranslateX = 7;
  initialProps->initialContentTranslateY = -9;
  initialProps->initialContentScale = 0.75;
  facebook::react::Props::Shared emptyProps;
  facebook::react::Props::Shared initialShared = initialProps;

  [host updateProps:initialShared oldProps:emptyProps];

  const smoothclip::Presentation initial =
      smoothclip::snapshotCurrent(driverId);
  XCTAssertEqual(smoothclip::registeredViewCount(driverId), 1u);
  XCTAssertEqualWithAccuracy(initial.clip.x, 10, 1e-9);
  XCTAssertEqualWithAccuracy(initial.clip.y, 20, 1e-9);
  XCTAssertEqualWithAccuracy(initial.clip.width, 120, 1e-9);
  XCTAssertEqualWithAccuracy(initial.clip.height, 80, 1e-9);
  XCTAssertEqualWithAccuracy(initial.clip.radius, 0, 1e-9);
  XCTAssertEqualWithAccuracy(initial.clip.topLeftRadius, 32, 1e-9);
  XCTAssertEqualWithAccuracy(initial.clip.topRightRadius, 20, 1e-9);
  XCTAssertEqualWithAccuracy(initial.clip.bottomRightRadius, 12, 1e-9);
  XCTAssertEqualWithAccuracy(initial.clip.bottomLeftRadius, 4, 1e-9);
  XCTAssertEqual(initial.clip.curve, smoothclip::ClipCurve::Continuous);
  XCTAssertEqualWithAccuracy(initial.contentTranslateX, 7, 1e-9);
  XCTAssertEqualWithAccuracy(initial.contentTranslateY, -9, 1e-9);
  XCTAssertEqualWithAccuracy(initial.contentScale, 0.75, 1e-9);

  auto invalidProps =
      std::make_shared<facebook::react::SmoothClipViewProps>();
  invalidProps->driverId = rejectedDriverId;
  invalidProps->presentationVersion = initialProps->presentationVersion;
  invalidProps->initialClipX = 90;
  invalidProps->initialClipY = initialProps->initialClipY;
  invalidProps->initialClipWidth = initialProps->initialClipWidth;
  invalidProps->initialClipHeight = initialProps->initialClipHeight;
  invalidProps->initialClipRadius = initialProps->initialClipRadius;
  invalidProps->initialClipTopLeftRadius =
      initialProps->initialClipTopLeftRadius;
  invalidProps->initialClipTopRightRadius =
      initialProps->initialClipTopRightRadius;
  invalidProps->initialClipBottomRightRadius =
      initialProps->initialClipBottomRightRadius;
  invalidProps->initialClipBottomLeftRadius =
      initialProps->initialClipBottomLeftRadius;
  invalidProps->initialClipCurve = initialProps->initialClipCurve;
  invalidProps->initialContentTranslateX =
      initialProps->initialContentTranslateX;
  invalidProps->initialContentTranslateY =
      initialProps->initialContentTranslateY;
  invalidProps->initialContentScale = 0;
  facebook::react::Props::Shared invalidShared = invalidProps;

  [host updateProps:invalidShared oldProps:initialShared];

  const smoothclip::Presentation afterReject =
      smoothclip::snapshotCurrent(driverId);
  XCTAssertEqual(smoothclip::registeredViewCount(driverId), 1u);
  XCTAssertEqual(smoothclip::registeredViewCount(rejectedDriverId), 0u);
  XCTAssertEqualWithAccuracy(afterReject.clip.x, initial.clip.x, 1e-9);
  XCTAssertEqualWithAccuracy(
      afterReject.clip.topLeftRadius, initial.clip.topLeftRadius, 1e-9);
  XCTAssertEqual(afterReject.clip.curve, initial.clip.curve);
  XCTAssertEqualWithAccuracy(
      afterReject.contentTranslateX, initial.contentTranslateX, 1e-9);
  XCTAssertEqualWithAccuracy(
      afterReject.contentScale, initial.contentScale, 1e-9);

  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
  smoothclip::destroyDriver(rejectedDriverId);
}

- (void)testFabricVersionZeroPreservesOldJSV1InitialProps {
  constexpr uint64_t driverId = 99072;
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  auto props = std::make_shared<facebook::react::SmoothClipViewProps>();
  props->driverId = driverId;
  // Old JS does not send presentationVersion or any widened props. Their
  // generated defaults (notably V2 scale zero) must not contaminate V1.
  props->initialClipX = 8;
  props->initialClipY = 9;
  props->initialClipWidth = 100;
  props->initialClipHeight = 70;
  props->initialClipRadius = 18;
  props->initialContentTranslateX = -8;
  props->initialContentTranslateY = -9;
  facebook::react::Props::Shared emptyProps;
  facebook::react::Props::Shared propsShared = props;

  [host updateProps:propsShared oldProps:emptyProps];

  const smoothclip::Presentation snapshot =
      smoothclip::snapshotCurrent(driverId);
  XCTAssertEqualWithAccuracy(snapshot.clip.x, 8, 1e-9);
  XCTAssertEqualWithAccuracy(snapshot.clip.y, 9, 1e-9);
  XCTAssertEqualWithAccuracy(snapshot.clip.width, 100, 1e-9);
  XCTAssertEqualWithAccuracy(snapshot.clip.height, 70, 1e-9);
  XCTAssertEqualWithAccuracy(snapshot.clip.radius, 18, 1e-9);
  XCTAssertEqual(snapshot.clip.curve, smoothclip::ClipCurve::Circular);
  XCTAssertEqualWithAccuracy(snapshot.contentTranslateX, -8, 1e-9);
  XCTAssertEqualWithAccuracy(snapshot.contentTranslateY, -9, 1e-9);
  XCTAssertEqualWithAccuracy(snapshot.contentScale, 1, 1e-9);

  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

- (void)testFabricV2CommandRejectsInvalidAggregatesWithoutTakingOwnership {
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));

  // An invalid command must not become authoritative; the next declarative
  // initial presentation must still apply.
  [host setClipPresentationV2:90
                            y:90
                        width:80
                       height:70
                topLeftRadius:16
               topRightRadius:16
            bottomRightRadius:16
             bottomLeftRadius:16
                    curveCode:0
            contentTranslateX:50
            contentTranslateY:60
                 contentScale:0];
  auto props = std::make_shared<facebook::react::SmoothClipViewProps>();
  props->presentationVersion = 2;
  props->initialClipX = 5;
  props->initialClipY = 6;
  props->initialClipWidth = 70;
  props->initialClipHeight = 60;
  props->initialClipTopLeftRadius = 14;
  props->initialClipTopRightRadius = 14;
  props->initialClipBottomRightRadius = 14;
  props->initialClipBottomLeftRadius = 14;
  props->initialClipCurve = 0;
  props->initialContentTranslateX = 2;
  props->initialContentTranslateY = 3;
  props->initialContentScale = 1;
  facebook::react::Props::Shared emptyProps;
  facebook::react::Props::Shared propsShared = props;
  [host updateProps:propsShared oldProps:emptyProps];
  const smoothclip::Presentation declarative =
      [host smoothClipCurrentPresentation];
  XCTAssertEqualWithAccuracy(declarative.clip.x, 5, 1e-9);
  XCTAssertEqualWithAccuracy(declarative.contentTranslateX, 2, 1e-9);

  [host setClipPresentationV2:10
                            y:20
                        width:120
                       height:80
                topLeftRadius:32
               topRightRadius:20
            bottomRightRadius:12
             bottomLeftRadius:4
                    curveCode:1
            contentTranslateX:11
            contentTranslateY:-7
                 contentScale:0.6];
  const smoothclip::Presentation valid =
      [host smoothClipCurrentPresentation];
  XCTAssertEqualWithAccuracy(valid.clip.x, 10, 1e-9);
  XCTAssertEqualWithAccuracy(valid.clip.topLeftRadius, 32, 1e-9);
  XCTAssertEqualWithAccuracy(valid.clip.bottomLeftRadius, 4, 1e-9);
  XCTAssertEqual(valid.clip.curve, smoothclip::ClipCurve::Continuous);
  XCTAssertEqualWithAccuracy(valid.contentTranslateX, 11, 1e-9);
  XCTAssertEqualWithAccuracy(valid.contentTranslateY, -7, 1e-9);
  XCTAssertEqualWithAccuracy(valid.contentScale, 0.6, 1e-9);

  [host setClipPresentationV2:100
                            y:100
                        width:20
                       height:20
                topLeftRadius:1
               topRightRadius:2
            bottomRightRadius:3
             bottomLeftRadius:4
                    curveCode:7
            contentTranslateX:40
            contentTranslateY:50
                 contentScale:1];
  const smoothclip::Presentation afterReject =
      [host smoothClipCurrentPresentation];
  XCTAssertEqualWithAccuracy(afterReject.clip.x, valid.clip.x, 1e-9);
  XCTAssertEqualWithAccuracy(
      afterReject.clip.topLeftRadius, valid.clip.topLeftRadius, 1e-9);
  XCTAssertEqualWithAccuracy(
      afterReject.clip.bottomLeftRadius, valid.clip.bottomLeftRadius, 1e-9);
  XCTAssertEqual(afterReject.clip.curve, valid.clip.curve);
  XCTAssertEqualWithAccuracy(
      afterReject.contentTranslateX, valid.contentTranslateX, 1e-9);
  XCTAssertEqualWithAccuracy(
      afterReject.contentScale, valid.contentScale, 1e-9);

  [host setClipPresentationV2:100
                            y:100
                        width:NAN
                       height:20
                topLeftRadius:1
               topRightRadius:2
            bottomRightRadius:3
             bottomLeftRadius:4
                    curveCode:1
            contentTranslateX:40
            contentTranslateY:50
                 contentScale:1];
  const smoothclip::Presentation afterNonFiniteReject =
      [host smoothClipCurrentPresentation];
  XCTAssertEqualWithAccuracy(
      afterNonFiniteReject.clip.x, valid.clip.x, 1e-9);
  XCTAssertEqualWithAccuracy(
      afterNonFiniteReject.clip.topLeftRadius,
      valid.clip.topLeftRadius,
      1e-9);
  XCTAssertEqual(afterNonFiniteReject.clip.curve, valid.clip.curve);
  XCTAssertEqualWithAccuracy(
      afterNonFiniteReject.contentScale, valid.contentScale, 1e-9);
}

- (void)testV2StaticPresentationUsesUnequalMaskAndUnscaledTranslation {
  constexpr uint64_t driverId = 9070;
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  const smoothclip::Presentation initial = Presentation(0, 0, 50, 50, 8);
  const smoothclip::Presentation value = PresentationV2(
      10,
      20,
      120,
      80,
      32,
      20,
      12,
      4,
      smoothclip::ClipCurve::Continuous,
      11,
      -7,
      0.6);

  smoothclip::registerView(driverId, host, initial);
  smoothclip::setPresentation(driverId, value, true);

  UIView *clip = [host valueForKey:@"clipContainer"];
  UIView *content = [host valueForKey:@"contentContainer"];
  XCTAssertTrue([clip.layer.mask isKindOfClass:CAShapeLayer.class]);
  XCTAssertEqual(clip.layer.cornerRadius, 0);
  XCTAssertTrue(((CAShapeLayer *)clip.layer.mask).path != nil);
  const CGAffineTransform transform = content.layer.affineTransform;
  XCTAssertEqualWithAccuracy(transform.a, 0.6, 1e-9);
  XCTAssertEqualWithAccuracy(transform.d, 0.6, 1e-9);
  // Scaling stays centered while translation retains unscaled point units.
  XCTAssertEqualWithAccuracy(transform.tx, 11, 1e-9);
  XCTAssertEqualWithAccuracy(transform.ty, -7, 1e-9);

  const smoothclip::Presentation snapshot = smoothclip::snapshotCurrent(driverId);
  XCTAssertEqualWithAccuracy(snapshot.clip.topLeftRadius, 32, 1e-9);
  XCTAssertEqualWithAccuracy(snapshot.clip.topRightRadius, 20, 1e-9);
  XCTAssertEqualWithAccuracy(snapshot.clip.bottomRightRadius, 12, 1e-9);
  XCTAssertEqualWithAccuracy(snapshot.clip.bottomLeftRadius, 4, 1e-9);
  XCTAssertEqual(snapshot.clip.curve, smoothclip::ClipCurve::Continuous);
  XCTAssertEqualWithAccuracy(snapshot.contentScale, 0.6, 1e-9);

  smoothclip::unregisterView(driverId, host);
  smoothclip::destroyDriver(driverId);
}

- (void)testUniformContinuousFastPathAndV1ResetPreserveLegacyRendering {
  constexpr uint64_t driverId = 9071;
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  smoothclip::registerView(driverId, host, Presentation(0, 0, 50, 50, 8));
  smoothclip::setPresentation(
      driverId,
      PresentationV2(
          0, 0, 100, 80, 18, 18, 18, 18,
          smoothclip::ClipCurve::Continuous, 3, 4, 0.75),
      true);

  UIView *clip = [host valueForKey:@"clipContainer"];
  UIView *content = [host valueForKey:@"contentContainer"];
  XCTAssertNil(clip.layer.mask);
  XCTAssertEqualWithAccuracy(clip.layer.cornerRadius, 18, 1e-9);
  XCTAssertEqualObjects(clip.layer.cornerCurve, kCACornerCurveContinuous);

  // A legacy write must restore the exact V1 fast path and implicit scale 1.
  smoothclip::setPresentation(
      driverId, Presentation(0, 0, 90, 70, 12, -5, 6), true);
  XCTAssertNil(clip.layer.mask);
  XCTAssertEqualWithAccuracy(clip.layer.cornerRadius, 12, 1e-9);
  XCTAssertEqualObjects(clip.layer.cornerCurve, kCACornerCurveCircular);
  XCTAssertEqualWithAccuracy(content.layer.affineTransform.a, 1, 1e-9);
  XCTAssertEqualWithAccuracy(content.layer.affineTransform.tx, -5, 1e-9);
  XCTAssertEqualWithAccuracy(content.layer.affineTransform.ty, 6, 1e-9);

  smoothclip::unregisterView(driverId, host);
  smoothclip::destroyDriver(driverId);
}

- (void)testV2TimingSnapshotDoesNotCancelMaskAndScaleAnimation {
  constexpr uint64_t driverId = 9072;
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  [host setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation initial = PresentationV2(
      0, 0, 50, 50, 10, 10, 10, 10,
      smoothclip::ClipCurve::Circular, 0, 0, 1);
  const smoothclip::Presentation target = PresentationV2(
      10, 20, 140, 100, 30, 18, 10, 2,
      smoothclip::ClipCurve::Circular, 12, -8, 0.5);
  smoothclip::registerView(driverId, host, initial);
  const int32_t animationId = smoothclip::animateTiming(
      driverId,
      {true, initial},
      target,
      {250, 0.42, 0, 0.58, 1, 2});
  XCTAssertGreaterThan(animationId, 0);

  UIView *clip = [host valueForKey:@"clipContainer"];
  UIView *content = [host valueForKey:@"contentContainer"];
  CAShapeLayer *mask = (CAShapeLayer *)clip.layer.mask;
  XCTAssertNotNil(mask);
  XCTAssertNotNil([mask animationForKey:@"smoothClip.mask"]);
  CAAnimationGroup *contentGroup = (CAAnimationGroup *)[content.layer
      animationForKey:@"smoothClip.content"];
  XCTAssertEqual(contentGroup.animations.count, 3u);

  const smoothclip::Presentation snapshot = smoothclip::snapshotCurrent(driverId);
  XCTAssertTrue(std::isfinite(snapshot.contentScale));
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  const smoothclip::Presentation frozen = smoothclip::beginInteraction(driverId);
  XCTAssertTrue(std::isfinite(frozen.clip.topLeftRadius));
  XCTAssertTrue(std::isfinite(frozen.contentScale));
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));

  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

- (void)testV2CurveChangingTimingRejectsWithoutMutation {
  constexpr uint64_t driverId = 99073;
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  [host setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation initial = PresentationV2(
      5, 6, 80, 70, 16, 16, 16, 16,
      smoothclip::ClipCurve::Circular, 2, 3, 1);
  const smoothclip::Presentation target = PresentationV2(
      20, 30, 120, 100, 30, 22, 14, 6,
      smoothclip::ClipCurve::Continuous, 11, -7, 0.6);
  smoothclip::registerView(driverId, host, initial);
  const smoothclip::Presentation before =
      smoothclip::snapshotCurrent(driverId);
  int completionCount = 0;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver, int32_t, bool) {
        if (completedDriver == driverId) completionCount += 1;
      });

  const int32_t animationId = smoothclip::animateTiming(
      driverId,
      {true, initial},
      target,
      {250, 0.42, 0, 0.58, 1, 2});

  XCTAssertEqual(animationId, 0);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));
  XCTAssertEqual(completionCount, 0);
  const smoothclip::Presentation after =
      smoothclip::snapshotCurrent(driverId);
  XCTAssertEqualWithAccuracy(after.clip.x, before.clip.x, 1e-9);
  XCTAssertEqualWithAccuracy(after.clip.y, before.clip.y, 1e-9);
  XCTAssertEqualWithAccuracy(after.clip.width, before.clip.width, 1e-9);
  XCTAssertEqualWithAccuracy(after.clip.height, before.clip.height, 1e-9);
  XCTAssertEqualWithAccuracy(
      after.clip.topLeftRadius, before.clip.topLeftRadius, 1e-9);
  XCTAssertEqual(after.clip.curve, before.clip.curve);
  XCTAssertEqualWithAccuracy(
      after.contentTranslateX, before.contentTranslateX, 1e-9);
  XCTAssertEqualWithAccuracy(
      after.contentTranslateY, before.contentTranslateY, 1e-9);
  XCTAssertEqualWithAccuracy(after.contentScale, before.contentScale, 1e-9);

  smoothclip::clearCompletionCallback((__bridge const void *)self);
  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

- (void)testTimingRejectsWhenAnyKnownHostWouldNormalizeButStaticClippingWorks {
  constexpr uint64_t driverId = 99074;
  UIWindow *window = TestWindow();
  SmoothClipView *largeHost =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  SmoothClipView *smallHost =
      DisplayableView(window, CGRectMake(0, 0, 100, 100));
  [largeHost setValue:@(driverId) forKey:@"driverId"];
  [smallHost setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation initial = PresentationV2(
      10, 10, 60, 60, 12, 12, 12, 12,
      smoothclip::ClipCurve::Circular, 0, 0, 1);
  const smoothclip::Presentation crossing = PresentationV2(
      80, 10, 40, 60, 12, 12, 12, 12,
      smoothclip::ClipCurve::Circular, 5, -3, 0.8);
  smoothclip::registerView(driverId, largeHost, initial);
  smoothclip::registerView(driverId, smallHost, initial);

  const int32_t animationId = smoothclip::animateTiming(
      driverId,
      {true, initial},
      crossing,
      {250, 0.42, 0, 0.58, 1, 2});

  XCTAssertEqual(animationId, 0);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));
  const smoothclip::Presentation afterReject =
      [smallHost smoothClipCurrentPresentation];
  XCTAssertEqualWithAccuracy(afterReject.clip.x, initial.clip.x, 1e-9);
  XCTAssertEqualWithAccuracy(afterReject.clip.width, initial.clip.width, 1e-9);

  // The guard applies only to autonomous interpolation. Static delivery still
  // clips independently for every host, including the smaller aperture.
  smoothclip::setPresentation(driverId, crossing, true);
  const smoothclip::Presentation largeStatic =
      [largeHost smoothClipCurrentPresentation];
  const smoothclip::Presentation smallStatic =
      [smallHost smoothClipCurrentPresentation];
  XCTAssertEqualWithAccuracy(largeStatic.clip.x, 80, 1e-9);
  XCTAssertEqualWithAccuracy(largeStatic.clip.width, 40, 1e-9);
  XCTAssertEqualWithAccuracy(smallStatic.clip.x, 80, 1e-9);
  XCTAssertEqualWithAccuracy(smallStatic.clip.width, 20, 1e-9);
  XCTAssertEqualWithAccuracy(smallStatic.contentScale, 0.8, 1e-9);

  smoothclip::unregisterView(driverId, largeHost);
  smoothclip::unregisterView(driverId, smallHost);
  [largeHost setValue:@0 forKey:@"driverId"];
  [smallHost setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

- (void)testLegacyV1AnimationsKeepFiniteClampingAndSkipV2NormalizationPreflight {
  constexpr uint64_t driverId = 9907401;
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 100, 100));
  [host setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation initial =
      Presentation(10, 10, 50, 50, 12);
  const smoothclip::Presentation crossing =
      Presentation(75, -20, 100, 140, 200, 4, -7);
  smoothclip::registerView(driverId, host, initial);

  const int32_t timingId = smoothclip::animateTiming(
      driverId,
      {true, initial},
      crossing,
      {250, 1.5, 0, -0.5, 1, 2},
      smoothclip::AnimationValidationMode::LegacyV1);
  XCTAssertGreaterThan(timingId, 0);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  smoothclip::cancelAnimation(driverId, timingId, false);

  const int32_t springId = smoothclip::animateSpring(
      driverId,
      {true, initial},
      crossing,
      {-2, 0, -4, -3, false, 1},
      smoothclip::AnimationValidationMode::LegacyV1);
  XCTAssertGreaterThan(springId, 0);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));

  std::vector<smoothclip::Keyframe> frames{
      {0, crossing},
      {0.5, Presentation(-80, 20, 240, 60, 300)},
      {1, initial},
  };
  const int32_t keyframeId = smoothclip::animateKeyframes(
      driverId,
      {true, crossing},
      initial,
      250,
      std::move(frames),
      2,
      smoothclip::AnimationValidationMode::LegacyV1);
  XCTAssertGreaterThan(keyframeId, 0);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  smoothclip::cancelAnimation(driverId, keyframeId, false);

  const int32_t clampedDurationId = smoothclip::animateTiming(
      driverId,
      {true, initial},
      crossing,
      {-50, 0.42, 0, 0.58, 1, 2},
      smoothclip::AnimationValidationMode::LegacyV1);
  XCTAssertGreaterThan(clampedDurationId, 0);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));

  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

- (void)testExplicitV2StartRejectionsDoNotReplaceExistingOwnership {
  constexpr uint64_t driverId = 9907402;
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 100, 100));
  [host setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation initial = PresentationV2(
      10, 10, 40, 40, 10, 8, 6, 4,
      smoothclip::ClipCurve::Circular, 0, 0, 1);
  const smoothclip::Presentation oldTarget = PresentationV2(
      20, 20, 60, 60, 12, 10, 8, 6,
      smoothclip::ClipCurve::Circular, 3, -2, 1);
  const smoothclip::Presentation crossing = PresentationV2(
      70, 10, 80, 60, 20, 16, 12, 8,
      smoothclip::ClipCurve::Circular, 8, -4, 0.8);
  smoothclip::registerView(driverId, host, initial);
  const smoothclip::TimingAnimation timing{500, 0.42, 0, 0.58, 1, 2};
  const int32_t oldId = smoothclip::animateTiming(
      driverId, {true, initial}, oldTarget, timing);
  XCTAssertGreaterThan(oldId, 0);

  XCTAssertEqual(
      smoothclip::animateTiming(
          driverId, {true, initial}, crossing, timing),
      0);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));

  std::vector<smoothclip::Keyframe> mismatchedFrames{
      {0, oldTarget},
      {1, oldTarget},
  };
  XCTAssertEqual(
      smoothclip::animateKeyframes(
          driverId,
          {true, initial},
          oldTarget,
          250,
          std::move(mismatchedFrames),
          2),
      0);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  const smoothclip::CancelResult cancelled =
      smoothclip::cancelAnimation(driverId, oldId, false);
  XCTAssertTrue(cancelled.handled);

  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

- (void)testKeyframesRejectOutOfBoundsIntermediateWithoutMutation {
  constexpr uint64_t driverId = 99075;
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 100, 100));
  [host setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation initial = PresentationV2(
      10, 10, 60, 60, 10, 10, 10, 10,
      smoothclip::ClipCurve::Circular, 0, 0, 1);
  const smoothclip::Presentation crossing = PresentationV2(
      -20, 10, 80, 60, 10, 10, 10, 10,
      smoothclip::ClipCurve::Circular, 4, -2, 0.9);
  const smoothclip::Presentation target = PresentationV2(
      20, 20, 50, 50, 8, 8, 8, 8,
      smoothclip::ClipCurve::Circular, 8, -4, 0.8);
  smoothclip::registerView(driverId, host, initial);
  const std::vector<smoothclip::Keyframe> frames{
      {0, initial},
      {0.5, crossing},
      {1, target},
  };

  const int32_t animationId = smoothclip::animateKeyframes(
      driverId, {true, initial}, target, 250, frames, 2);

  XCTAssertEqual(animationId, 0);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));
  const smoothclip::Presentation afterReject =
      smoothclip::snapshotCurrent(driverId);
  XCTAssertEqualWithAccuracy(afterReject.clip.x, initial.clip.x, 1e-9);
  XCTAssertEqualWithAccuracy(afterReject.clip.y, initial.clip.y, 1e-9);
  XCTAssertEqualWithAccuracy(afterReject.clip.width, initial.clip.width, 1e-9);
  XCTAssertEqualWithAccuracy(
      afterReject.contentTranslateX, initial.contentTranslateX, 1e-9);
  XCTAssertEqualWithAccuracy(
      afterReject.contentScale, initial.contentScale, 1e-9);

  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

- (void)testNormalizationRejectsGroupReplacementAtomically {
  constexpr uint64_t firstDriverId = 99076;
  constexpr uint64_t secondDriverId = 99077;
  UIWindow *window = TestWindow();
  SmoothClipView *first =
      DisplayableView(window, CGRectMake(0, 0, 100, 100));
  SmoothClipView *second =
      DisplayableView(window, CGRectMake(0, 0, 100, 100));
  [first setValue:@(firstDriverId) forKey:@"driverId"];
  [second setValue:@(secondDriverId) forKey:@"driverId"];
  const smoothclip::Presentation initial = PresentationV2(
      10, 10, 40, 40, 8, 8, 8, 8,
      smoothclip::ClipCurve::Circular, 0, 0, 1);
  const smoothclip::Presentation oldTarget = PresentationV2(
      20, 20, 60, 60, 12, 12, 12, 12,
      smoothclip::ClipCurve::Circular, 3, -2, 0.9);
  const smoothclip::Presentation safeReplacement = PresentationV2(
      25, 20, 50, 50, 10, 10, 10, 10,
      smoothclip::ClipCurve::Circular, 4, -3, 0.85);
  const smoothclip::Presentation crossingReplacement = PresentationV2(
      80, 20, 40, 50, 10, 10, 10, 10,
      smoothclip::ClipCurve::Circular, 4, -3, 0.85);
  smoothclip::registerView(firstDriverId, first, initial);
  smoothclip::registerView(secondDriverId, second, initial);

  struct GroupEvent {
    int32_t groupId;
    bool finished;
  };
  std::vector<GroupEvent> events;
  smoothclip::setGroupCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t,
          int32_t groupId,
          bool finished,
          std::vector<uint64_t>) {
        events.push_back({groupId, finished});
      });
  const smoothclip::TimingAnimation timing{500, 0.42, 0, 0.58, 1, 2};
  const int32_t oldGroupId = smoothclip::animateTimingGroup(
      99100,
      {
          GroupEntry(firstDriverId, true, initial, oldTarget),
          GroupEntry(secondDriverId, true, initial, oldTarget),
      },
      timing,
      smoothclip::GroupSuspensionPolicy::Pause);
  XCTAssertGreaterThan(oldGroupId, 0);

  const int32_t rejectedGroupId = smoothclip::animateTimingGroup(
      99101,
      {
          GroupEntry(firstDriverId, false, initial, safeReplacement),
          GroupEntry(secondDriverId, false, initial, crossingReplacement),
      },
      timing,
      smoothclip::GroupSuspensionPolicy::Pause);

  XCTAssertEqual(rejectedGroupId, 0);
  XCTAssertTrue(smoothclip::hasActiveAnimation(firstDriverId));
  XCTAssertTrue(smoothclip::hasActiveAnimation(secondDriverId));
  XCTAssertEqual(events.size(), 0u);
  const std::vector<smoothclip::DriverSnapshot> frozen =
      smoothclip::cancelAnimationGroup(
          oldGroupId, smoothclip::GroupCancelBehavior::Freeze);
  XCTAssertEqual(frozen.size(), 2u);
  XCTAssertEqual(events.size(), 1u);
  XCTAssertEqual(events[0].groupId, oldGroupId);
  XCTAssertFalse(events[0].finished);

  smoothclip::clearGroupCompletionCallback((__bridge const void *)self);
  smoothclip::unregisterView(firstDriverId, first);
  smoothclip::unregisterView(secondDriverId, second);
  [first setValue:@0 forKey:@"driverId"];
  [second setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(firstDriverId);
  smoothclip::destroyDriver(secondDriverId);
}

- (void)testGroupWaitsForEveryDriverAndInstallsOneAbsoluteBeginTime {
  constexpr uint64_t firstDriverId = 9073;
  constexpr uint64_t secondDriverId = 9074;
  UIWindow *window = TestWindow();
  SmoothClipView *first =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  SmoothClipView *second =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  [second removeFromSuperview];
  [first setValue:@(firstDriverId) forKey:@"driverId"];
  [second setValue:@(secondDriverId) forKey:@"driverId"];

  const smoothclip::Presentation initial = PresentationV2(
      0, 0, 50, 50, 12, 12, 12, 12,
      smoothclip::ClipCurve::Circular, 0, 0, 1);
  const smoothclip::Presentation target = PresentationV2(
      20, 30, 140, 100, 28, 20, 12, 4,
      smoothclip::ClipCurve::Circular, 8, -6, 0.7);
  smoothclip::registerView(firstDriverId, first, initial);
  smoothclip::registerView(secondDriverId, second, initial);

  const int32_t groupId = smoothclip::animateTimingGroup(
      7001,
      {
          GroupEntry(firstDriverId, true, initial, target),
          GroupEntry(secondDriverId, true, initial, target),
      },
      {250, 0.42, 0, 0.58, 1, 2},
      smoothclip::GroupSuspensionPolicy::Pause);
  XCTAssertGreaterThan(groupId, 0);
  CALayer *firstLayer =
      ((UIView *)[first valueForKey:@"clipContainer"]).layer;
  CALayer *secondLayer =
      ((UIView *)[second valueForKey:@"clipContainer"]).layer;
  // The first participant is ready, but the initial barrier is all-or-none.
  XCTAssertNil([firstLayer animationForKey:@"smoothClip.geometry"]);
  XCTAssertNil([secondLayer animationForKey:@"smoothClip.geometry"]);

  [window addSubview:second];
  CAAnimationGroup *firstAnimation = (CAAnimationGroup *)[firstLayer
      animationForKey:@"smoothClip.geometry"];
  CAAnimationGroup *secondAnimation = (CAAnimationGroup *)[secondLayer
      animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(firstAnimation);
  XCTAssertNotNil(secondAnimation);
  const CFTimeInterval firstAbsolute =
      [firstLayer convertTime:firstAnimation.beginTime toLayer:nil];
  const CFTimeInterval secondAbsolute =
      [secondLayer convertTime:secondAnimation.beginTime toLayer:nil];
  XCTAssertEqualWithAccuracy(firstAbsolute, secondAbsolute, 1e-9);

  smoothclip::cancelAnimationGroup(
      groupId, smoothclip::GroupCancelBehavior::Freeze);
  smoothclip::unregisterView(firstDriverId, first);
  smoothclip::unregisterView(secondDriverId, second);
  [first setValue:@0 forKey:@"driverId"];
  [second setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(firstDriverId);
  smoothclip::destroyDriver(secondDriverId);
}

- (void)testInvalidGroupReplacementIsAtomicAndValidOverlapCreatesANewEpoch {
  constexpr uint64_t firstDriverId = 9075;
  constexpr uint64_t secondDriverId = 9076;
  constexpr uint64_t thirdDriverId = 9077;
  constexpr uint64_t missingDriverId = 9999077;
  UIWindow *window = TestWindow();
  SmoothClipView *first =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  SmoothClipView *second =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  SmoothClipView *third =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  [first setValue:@(firstDriverId) forKey:@"driverId"];
  [second setValue:@(secondDriverId) forKey:@"driverId"];
  [third setValue:@(thirdDriverId) forKey:@"driverId"];
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 12);
  const smoothclip::Presentation firstTarget =
      Presentation(10, 10, 120, 100, 18);
  const smoothclip::Presentation replacementTarget =
      Presentation(20, 30, 150, 130, 24);
  smoothclip::registerView(firstDriverId, first, initial);
  smoothclip::registerView(secondDriverId, second, initial);
  smoothclip::registerView(thirdDriverId, third, initial);

  struct GroupEvent {
    uint64_t controllerId;
    int32_t groupId;
    bool finished;
    std::vector<uint64_t> driverIds;
  };
  std::vector<GroupEvent> events;
  int singleCompletionCount = 0;
  smoothclip::setGroupCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t controllerId,
          int32_t completedGroupId,
          bool finished,
          std::vector<uint64_t> driverIds) {
        events.push_back(
            {controllerId, completedGroupId, finished, std::move(driverIds)});
      });
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t, int32_t, bool) { singleCompletionCount += 1; });

  const smoothclip::TimingAnimation timing{500, 0.42, 0, 0.58, 1, 2};
  const int32_t oldGroupId = smoothclip::animateTimingGroup(
      7002,
      {
          GroupEntry(firstDriverId, true, initial, firstTarget),
          GroupEntry(secondDriverId, true, initial, firstTarget),
      },
      timing,
      smoothclip::GroupSuspensionPolicy::Pause);
  XCTAssertGreaterThan(oldGroupId, 0);

  // The missing driver has no authoritative from value, so the entire
  // replacement rejects before it can freeze either old participant.
  const int32_t rejected = smoothclip::animateTimingGroup(
      7003,
      {
          GroupEntry(firstDriverId, false, initial, replacementTarget),
          GroupEntry(missingDriverId, false, initial, replacementTarget),
      },
      timing,
      smoothclip::GroupSuspensionPolicy::Pause);
  XCTAssertEqual(rejected, 0);
  XCTAssertTrue(smoothclip::hasActiveAnimation(firstDriverId));
  XCTAssertTrue(smoothclip::hasActiveAnimation(secondDriverId));
  XCTAssertEqual(events.size(), 0u);

  const int32_t replacementGroupId = smoothclip::animateTimingGroup(
      7004,
      {
          GroupEntry(firstDriverId, false, initial, replacementTarget),
          GroupEntry(thirdDriverId, false, initial, replacementTarget),
      },
      timing,
      smoothclip::GroupSuspensionPolicy::Pause);
  XCTAssertGreaterThan(replacementGroupId, 0);
  XCTAssertNotEqual(replacementGroupId, oldGroupId);
  XCTAssertEqual(events.size(), 1u);
  XCTAssertEqual(events[0].controllerId, 7002u);
  XCTAssertEqual(events[0].groupId, oldGroupId);
  XCTAssertFalse(events[0].finished);
  XCTAssertEqual(events[0].driverIds,
                 (std::vector<uint64_t>{firstDriverId, secondDriverId}));
  XCTAssertTrue(smoothclip::hasActiveAnimation(firstDriverId));
  XCTAssertFalse(smoothclip::hasActiveAnimation(secondDriverId));
  XCTAssertTrue(smoothclip::hasActiveAnimation(thirdDriverId));
  XCTAssertEqual(singleCompletionCount, 0);

  const std::vector<smoothclip::DriverSnapshot> frozen =
      smoothclip::cancelAnimationGroup(
          replacementGroupId, smoothclip::GroupCancelBehavior::Freeze);
  XCTAssertEqual(frozen.size(), 2u);
  XCTAssertEqual(frozen[0].driverId, firstDriverId);
  XCTAssertEqual(frozen[1].driverId, thirdDriverId);
  XCTAssertEqual(events.size(), 2u);
  XCTAssertFalse(events[1].finished);
  XCTAssertEqual(events[1].driverIds,
                 (std::vector<uint64_t>{firstDriverId, thirdDriverId}));
  XCTAssertEqual(singleCompletionCount, 0);

  smoothclip::clearCompletionCallback((__bridge const void *)self);
  smoothclip::clearGroupCompletionCallback((__bridge const void *)self);
  smoothclip::unregisterView(firstDriverId, first);
  smoothclip::unregisterView(secondDriverId, second);
  smoothclip::unregisterView(thirdDriverId, third);
  [first setValue:@0 forKey:@"driverId"];
  [second setValue:@0 forKey:@"driverId"];
  [third setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(firstDriverId);
  smoothclip::destroyDriver(secondDriverId);
  smoothclip::destroyDriver(thirdDriverId);
}

- (void)testBatchPreflightLeavesOldGroupUntouchedThenDissolvesItOnce {
  constexpr uint64_t firstDriverId = 9078;
  constexpr uint64_t secondDriverId = 9079;
  constexpr uint64_t missingDriverId = 9999079;
  UIWindow *window = TestWindow();
  SmoothClipView *first =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  SmoothClipView *second =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  [first setValue:@(firstDriverId) forKey:@"driverId"];
  [second setValue:@(secondDriverId) forKey:@"driverId"];
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 12);
  const smoothclip::Presentation target =
      Presentation(10, 10, 120, 100, 18);
  const smoothclip::Presentation batchValue = PresentationV2(
      30, 20, 100, 80, 28, 20, 12, 4,
      smoothclip::ClipCurve::Continuous, 7, -9, 0.8);
  smoothclip::registerView(firstDriverId, first, initial);
  smoothclip::registerView(secondDriverId, second, initial);

  int groupCompletionCount = 0;
  BOOL groupFinished = YES;
  std::vector<uint64_t> completedDrivers;
  smoothclip::setGroupCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t,
          int32_t,
          bool finished,
          std::vector<uint64_t> driverIds) {
        groupCompletionCount += 1;
        groupFinished = finished;
        completedDrivers = std::move(driverIds);
      });
  const int32_t groupId = smoothclip::animateTimingGroup(
      7005,
      {
          GroupEntry(firstDriverId, true, initial, target),
          GroupEntry(secondDriverId, true, initial, target),
      },
      {500, 0.42, 0, 0.58, 1, 2},
      smoothclip::GroupSuspensionPolicy::Pause);
  XCTAssertGreaterThan(groupId, 0);

  XCTAssertFalse(smoothclip::setPresentationBatch({
      {firstDriverId, batchValue},
      {missingDriverId, batchValue},
  }));
  XCTAssertTrue(smoothclip::hasActiveAnimation(firstDriverId));
  XCTAssertTrue(smoothclip::hasActiveAnimation(secondDriverId));
  XCTAssertEqual(groupCompletionCount, 0);

  XCTAssertTrue(smoothclip::setPresentationBatch({
      {firstDriverId, batchValue},
  }));
  XCTAssertFalse(smoothclip::hasActiveAnimation(firstDriverId));
  XCTAssertFalse(smoothclip::hasActiveAnimation(secondDriverId));
  XCTAssertEqual(groupCompletionCount, 1);
  XCTAssertFalse(groupFinished);
  XCTAssertEqual(completedDrivers,
                 (std::vector<uint64_t>{firstDriverId, secondDriverId}));
  const smoothclip::Presentation snapshot =
      smoothclip::snapshotCurrent(firstDriverId);
  XCTAssertEqualWithAccuracy(snapshot.clip.width, batchValue.clip.width, 1e-9);
  XCTAssertEqualWithAccuracy(snapshot.clip.topLeftRadius, 28, 1e-9);
  XCTAssertEqualWithAccuracy(snapshot.contentScale, 0.8, 1e-9);

  smoothclip::clearGroupCompletionCallback((__bridge const void *)self);
  smoothclip::unregisterView(firstDriverId, first);
  smoothclip::unregisterView(secondDriverId, second);
  [first setValue:@0 forKey:@"driverId"];
  [second setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(firstDriverId);
  smoothclip::destroyDriver(secondDriverId);
}

- (void)testGroupCompletionAggregatesAndExplicitFinishUsesTargets {
  constexpr uint64_t firstDriverId = 9080;
  constexpr uint64_t secondDriverId = 9081;
  UIWindow *window = TestWindow();
  SmoothClipView *first =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  SmoothClipView *second =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  [first setValue:@(firstDriverId) forKey:@"driverId"];
  [second setValue:@(secondDriverId) forKey:@"driverId"];
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 12);
  const smoothclip::Presentation target =
      Presentation(10, 10, 120, 100, 18);
  const smoothclip::Presentation finishTarget = PresentationV2(
      30, 20, 140, 110, 30, 22, 14, 6,
      smoothclip::ClipCurve::Circular, 5, -7, 0.75);
  smoothclip::registerView(firstDriverId, first, initial);
  smoothclip::registerView(secondDriverId, second, initial);

  struct GroupEvent {
    int32_t groupId;
    bool finished;
    std::vector<uint64_t> driverIds;
  };
  std::vector<GroupEvent> events;
  int singleCompletionCount = 0;
  smoothclip::setGroupCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t,
          int32_t groupId,
          bool finished,
          std::vector<uint64_t> driverIds) {
        events.push_back({groupId, finished, std::move(driverIds)});
      });
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t, int32_t, bool) { singleCompletionCount += 1; });

  const int32_t completedGroupId = smoothclip::animateTimingGroup(
      7006,
      {
          GroupEntry(firstDriverId, true, initial, target),
          GroupEntry(secondDriverId, true, initial, target),
      },
      {500, 0.42, 0, 0.58, 1, 2},
      smoothclip::GroupSuspensionPolicy::Pause);
  XCTAssertGreaterThan(completedGroupId, 0);
  smoothclip::viewAnimationDidStop(
      firstDriverId, completedGroupId, first, true);
  XCTAssertEqual(events.size(), 0u);
  XCTAssertTrue(smoothclip::hasActiveAnimation(secondDriverId));
  smoothclip::viewAnimationDidStop(
      secondDriverId, completedGroupId, second, true);
  XCTAssertEqual(events.size(), 1u);
  XCTAssertEqual(events[0].groupId, completedGroupId);
  XCTAssertTrue(events[0].finished);
  XCTAssertEqual(events[0].driverIds,
                 (std::vector<uint64_t>{firstDriverId, secondDriverId}));
  XCTAssertEqual(singleCompletionCount, 0);

  const int32_t finishGroupId = smoothclip::animateTimingGroup(
      7007,
      {
          GroupEntry(firstDriverId, true, target, finishTarget),
          GroupEntry(secondDriverId, true, target, finishTarget),
      },
      {500, 0.42, 0, 0.58, 1, 2},
      smoothclip::GroupSuspensionPolicy::Pause);
  XCTAssertGreaterThan(finishGroupId, 0);
  XCTAssertNotEqual(finishGroupId, completedGroupId);
  const std::vector<smoothclip::DriverSnapshot> finished =
      smoothclip::cancelAnimationGroup(
          finishGroupId, smoothclip::GroupCancelBehavior::Finish);
  XCTAssertEqual(finished.size(), 2u);
  XCTAssertEqualWithAccuracy(
      finished[0].presentation.clip.width, finishTarget.clip.width, 1e-9);
  XCTAssertEqualWithAccuracy(
      finished[1].presentation.contentScale, finishTarget.contentScale, 1e-9);
  XCTAssertEqual(events.size(), 2u);
  XCTAssertEqual(events[1].groupId, finishGroupId);
  XCTAssertTrue(events[1].finished);
  XCTAssertEqual(singleCompletionCount, 0);
  XCTAssertFalse(smoothclip::hasActiveAnimation(firstDriverId));
  XCTAssertFalse(smoothclip::hasActiveAnimation(secondDriverId));

  smoothclip::clearCompletionCallback((__bridge const void *)self);
  smoothclip::clearGroupCompletionCallback((__bridge const void *)self);
  smoothclip::unregisterView(firstDriverId, first);
  smoothclip::unregisterView(secondDriverId, second);
  [first setValue:@0 forKey:@"driverId"];
  [second setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(firstDriverId);
  smoothclip::destroyDriver(secondDriverId);
}

- (void)testGroupSuspensionPauseRelatchesAndFinishCompletesAtTargets {
  constexpr uint64_t firstDriverId = 9082;
  constexpr uint64_t secondDriverId = 9083;
  UIWindow *window = TestWindow();
  SmoothClipView *first =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  SmoothClipView *second =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  [first setValue:@(firstDriverId) forKey:@"driverId"];
  [second setValue:@(secondDriverId) forKey:@"driverId"];
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 12);
  const smoothclip::Presentation pausedTarget =
      Presentation(10, 10, 120, 100, 18);
  const smoothclip::Presentation finishTarget =
      Presentation(20, 20, 160, 140, 24);
  smoothclip::registerView(firstDriverId, first, initial);
  smoothclip::registerView(secondDriverId, second, initial);

  struct GroupEvent {
    int32_t groupId;
    bool finished;
  };
  std::vector<GroupEvent> events;
  smoothclip::setGroupCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t,
          int32_t groupId,
          bool finished,
          std::vector<uint64_t>) {
        events.push_back({groupId, finished});
      });
  const smoothclip::TimingAnimation timing{500, 0.42, 0, 0.58, 1, 2};
  const int32_t pauseGroupId = smoothclip::animateTimingGroup(
      7008,
      {
          GroupEntry(firstDriverId, true, initial, pausedTarget),
          GroupEntry(secondDriverId, true, initial, pausedTarget),
      },
      timing,
      smoothclip::GroupSuspensionPolicy::Pause);
  XCTAssertGreaterThan(pauseGroupId, 0);
  smoothclip::applicationWillResignActive();
  XCTAssertTrue(smoothclip::hasActiveAnimation(firstDriverId));
  XCTAssertTrue(smoothclip::hasActiveAnimation(secondDriverId));
  XCTAssertEqual(events.size(), 0u);
  XCTAssertNil([((UIView *)[first valueForKey:@"clipContainer"]).layer
      animationForKey:@"smoothClip.geometry"]);

  smoothclip::applicationDidBecomeActive();
  XCTAssertNotNil([((UIView *)[first valueForKey:@"clipContainer"]).layer
      animationForKey:@"smoothClip.geometry"]);
  smoothclip::cancelAnimationGroup(
      pauseGroupId, smoothclip::GroupCancelBehavior::Freeze);
  XCTAssertEqual(events.size(), 1u);
  XCTAssertFalse(events[0].finished);

  const int32_t finishGroupId = smoothclip::animateTimingGroup(
      7009,
      {
          GroupEntry(firstDriverId, false, pausedTarget, finishTarget),
          GroupEntry(secondDriverId, false, pausedTarget, finishTarget),
      },
      timing,
      smoothclip::GroupSuspensionPolicy::Finish);
  XCTAssertGreaterThan(finishGroupId, 0);
  smoothclip::applicationWillResignActive();
  XCTAssertFalse(smoothclip::hasActiveAnimation(firstDriverId));
  XCTAssertFalse(smoothclip::hasActiveAnimation(secondDriverId));
  XCTAssertEqual(events.size(), 2u);
  XCTAssertEqual(events[1].groupId, finishGroupId);
  XCTAssertTrue(events[1].finished);
  const smoothclip::Presentation firstSnapshot =
      smoothclip::snapshotCurrent(firstDriverId);
  XCTAssertEqualWithAccuracy(
      firstSnapshot.clip.width, finishTarget.clip.width, 1e-9);
  smoothclip::applicationDidBecomeActive();

  smoothclip::clearGroupCompletionCallback((__bridge const void *)self);
  smoothclip::unregisterView(firstDriverId, first);
  smoothclip::unregisterView(secondDriverId, second);
  [first setValue:@0 forKey:@"driverId"];
  [second setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(firstDriverId);
  smoothclip::destroyDriver(secondDriverId);
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
// target. A valid interactive start is authoritative enough to create the
// missing driver entry; no earlier hook seed is required.
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

// All three entry points share the pre-registration creation rule. Cover the
// two non-timing constructors so a future refactor cannot restore their old
// find-or-drop behavior while timing continues to pass.
- (void)testSpringAndKeyframesCreatePreRegistrationLatches {
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);

  constexpr uint64_t springDriverId = 9025;
  const smoothclip::SpringAnimation spring{1, 180, 18, 0, false, 2};
  XCTAssertGreaterThan(
      smoothclip::animateSpring(
          springDriverId, {true, initial}, target, spring),
      0);
  XCTAssertTrue(smoothclip::hasActiveAnimation(springDriverId));
  smoothclip::destroyDriver(springDriverId);

  constexpr uint64_t keyframeDriverId = 9026;
  std::vector<smoothclip::Keyframe> frames{
      {0, initial},
      {1, target},
  };
  XCTAssertGreaterThan(
      smoothclip::animateKeyframes(
          keyframeDriverId,
          {true, initial},
          target,
          250,
          std::move(frames),
          2),
      0);
  XCTAssertTrue(smoothclip::hasActiveAnimation(keyframeDriverId));
  smoothclip::destroyDriver(keyframeDriverId);
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

// The registry can no longer enforce "a destroyed driver does not resurrect":
// destroyDriver erases the entry, so a post-destroy request with a valid
// interactive start is byte-for-byte the pre-registration race R1 exists to
// accept. What survives here is the weaker native rule — a start-less request
// against a missing entry is still refused, and no entry point invents
// geometry. The lifetime half of the old guarantee moved to the UI runtime,
// where a `disposed` SharedValue rejects every call issued after the hook's
// cleanup; see the "rejects every call once the driver is disposed" case in
// src/__tests__/drivers.native.test.tsx. Deleting either half reopens a leaked
// latch whose completion never arrives.
- (void)testMissingDriverEntryPointsWithoutAStartFailDefined {
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
      smoothclip::animateTiming(driverId, {false, initial}, target, timing), 0);
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

  // Window attach (didMoveToWindow → displayability update) starts the
  // latch with the full duration, inside the attach commit.
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

// animation.from is fresher intent than a held latch. Its fused native write
// opts into one unfinished cancellation, establishes the new native start,
// and the replacement then freezes from that exact value.
- (void)testExplicitFromReplacesAHeldLatchOnce {
  constexpr uint64_t driverId = 9027;
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
  const smoothclip::Presentation firstTarget =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::Presentation from =
      Presentation(3, 4, 55, 45, 9, 7, 8);
  const smoothclip::Presentation replacementTarget =
      Presentation(1, 2, 80, 70, 10, -4, -5);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  const int32_t first = smoothclip::animateTiming(
      driverId, {true, initial}, firstTarget, timing);
  smoothclip::setPresentation(driverId, from, true, true);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));
  XCTAssertEqual(completionCount, 1);
  XCTAssertEqual(lastCompleted, first);
  XCTAssertFalse(lastFinished);

  const int32_t replacement = smoothclip::animateTiming(
      driverId, {false, initial}, replacementTarget, timing);
  XCTAssertGreaterThan(replacement, first);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  const smoothclip::Presentation frozen = smoothclip::beginInteraction(driverId);
  XCTAssertEqual(frozen.clip.x, from.clip.x);
  XCTAssertEqual(frozen.clip.width, from.clip.width);
  XCTAssertEqual(frozen.contentTranslateY, from.contentTranslateY);
  XCTAssertEqual(completionCount, 2);
  XCTAssertEqual(lastCompleted, replacement);
  XCTAssertFalse(lastFinished);

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

  // Window attach (didMoveToWindow → displayability update) completes the
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

// A detached peer is registered but cannot produce a frame. Removing the only
// displayable participant must therefore freeze and re-latch the animation;
// time spent waiting for the peer to attach cannot burn the saved remainder.
- (void)testRemovingSoleDisplayableHostRelatchesWithDetachedPeer {
  constexpr uint64_t driverId = 9028;
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
  SmoothClipView *displayable =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  SmoothClipView *detached = [[SmoothClipView alloc]
      initWithFrame:CGRectMake(0, 0, 120, 120)];
  facebook::react::LayoutMetrics metrics;
  metrics.frame = facebook::react::Rect{
      facebook::react::Point{0, 0}, facebook::react::Size{120, 120}};
  [detached updateLayoutMetrics:metrics
               oldLayoutMetrics:facebook::react::LayoutMetrics{}];
  [detached setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{120, 0.42, 0, 0.58, 1, 2};

  smoothclip::registerView(driverId, displayable, initial);
  smoothclip::registerView(driverId, detached, initial);
  smoothclip::animateTiming(driverId, {true, initial}, target, timing);
  smoothclip::unregisterView(driverId, displayable);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  XCTAssertEqual(completionCount, 0);

  // Wait longer than the original duration. A running clock would have
  // completed and the peer would snap; a latch still installs a real group.
  usleep(180000);
  [window addSubview:detached];
  UIView *container = [detached valueForKey:@"clipContainer"];
  CAAnimationGroup *group = (CAAnimationGroup *)[container.layer
      animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(group);
  XCTAssertGreaterThan(group.duration, 0);
  XCTAssertLessThanOrEqual(group.duration, 0.12 + 1e-3);
  XCTAssertEqual(completionCount, 0);

  smoothclip::cancelAnimation(driverId, 0, false);
  XCTAssertEqual(completionCount, 1);
  XCTAssertFalse(completedFinished);
  smoothclip::unregisterView(driverId, detached);
  smoothclip::clearCompletionCallback((__bridge const void *)self);
  smoothclip::destroyDriver(driverId);
}

// The other half of displayability re-latching. The surviving peer is not
// detached but un-laid-out, so it resumes through its FIRST LAYOUT, not a
// window attach. Before 0.2.7 joinActiveAnimation bailed on any un-started
// animation — a rule that held only while re-latching required an empty
// participant set — and the caller reacted by clearing the animation id and
// applying the requested geometry: the peer snapped to the target and the
// latch was stranded with no completion, ever.
- (void)testRelatchedAnimationResumesWhenADeferredPeerFirstLaysOut {
  constexpr uint64_t driverId = 9029;
  int completionCount = 0;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver, int32_t, bool) {
        if (completedDriver == driverId) completionCount += 1;
      });
  UIWindow *window = TestWindow();
  SmoothClipView *displayable =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  // Attached but never laid out: registers, then defers its install.
  SmoothClipView *pending = [[SmoothClipView alloc]
      initWithFrame:CGRectMake(0, 0, 120, 120)];
  [pending setValue:@(driverId) forKey:@"driverId"];
  [window addSubview:pending];
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  smoothclip::registerView(driverId, displayable, initial);
  smoothclip::registerView(driverId, pending, initial);
  smoothclip::animateTiming(driverId, {true, initial}, target, timing);
  UIView *container = [pending valueForKey:@"clipContainer"];
  XCTAssertNil([container.layer animationForKey:@"smoothClip.geometry"]);

  smoothclip::unregisterView(driverId, displayable);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  XCTAssertEqual(completionCount, 0);

  facebook::react::LayoutMetrics metrics;
  metrics.frame = facebook::react::Rect{
      facebook::react::Point{0, 0}, facebook::react::Size{120, 120}};
  [pending updateLayoutMetrics:metrics
              oldLayoutMetrics:facebook::react::LayoutMetrics{}];

  CAAnimationGroup *group = (CAAnimationGroup *)[container.layer
      animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(group);
  XCTAssertGreaterThan(group.duration, 0);
  // The join must start from the re-latched canonical presentation. If the
  // relayout pass fell through past its pending-install guard, it would
  // reinstall from this host's own zero rect instead.
  CABasicAnimation *bounds = (CABasicAnimation *)group.animations.firstObject;
  const CGRect resumedFrom = [bounds.fromValue CGRectValue];
  XCTAssertEqualWithAccuracy(resumedFrom.size.width, 100, 1e-6);
  XCTAssertEqual(completionCount, 0);

  smoothclip::cancelAnimation(driverId, 0, false);
  XCTAssertEqual(completionCount, 1);
  smoothclip::unregisterView(driverId, pending);
  smoothclip::clearCompletionCallback((__bridge const void *)self);
  smoothclip::destroyDriver(driverId);
}

// First layout is a displayability trigger in its own right, independent of
// any deferred install: when the host is inserted into its window BEFORE
// Fabric sends layout metrics, didMoveToWindow sees no layout and does
// nothing, so the layout pass is the only remaining signal. Android has
// always notified from both (setViewHostGeometryAndroid); iOS notified only
// on attach, which left this latch held forever.
- (void)testZeroSizedFirstLayoutKeepsTheLatchUntilPositiveLayout {
  constexpr uint64_t driverId = 9030;
  UIWindow *window = TestWindow();
  SmoothClipView *host = [[SmoothClipView alloc] initWithFrame:CGRectZero];
  [host setValue:@(driverId) forKey:@"driverId"];
  // Attach before layout: didMoveToWindow fires while _hasLayout is still NO,
  // so it cannot be the trigger.
  [window addSubview:host];
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  smoothclip::registerView(driverId, host, initial);
  smoothclip::animateTiming(driverId, {true, initial}, target, timing);
  UIView *container = [host valueForKey:@"clipContainer"];
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  XCTAssertNil([container.layer animationForKey:@"smoothClip.geometry"]);

  facebook::react::LayoutMetrics zeroMetrics;
  zeroMetrics.frame = facebook::react::Rect{
      facebook::react::Point{0, 0}, facebook::react::Size{0, 0}};
  [host updateLayoutMetrics:zeroMetrics
           oldLayoutMetrics:facebook::react::LayoutMetrics{}];
  usleep(300000);
  XCTAssertNil([container.layer animationForKey:@"smoothClip.geometry"]);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));

  facebook::react::LayoutMetrics metrics;
  metrics.frame = facebook::react::Rect{
      facebook::react::Point{0, 0}, facebook::react::Size{120, 120}};
  [host updateLayoutMetrics:metrics
           oldLayoutMetrics:zeroMetrics];

  CAAnimationGroup *group = (CAAnimationGroup *)[container.layer
      animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(group);
  // Rebased, not resumed mid-curve: the latch burns no time before it can be
  // seen, so the whole 250 ms is still ahead of it.
  XCTAssertEqualWithAccuracy(group.duration, 0.25, 1e-3);

  smoothclip::cancelAnimation(driverId, 0, false);
  smoothclip::unregisterView(driverId, host);
  smoothclip::destroyDriver(driverId);
}

// Freezing is a teardown side effect that must reach the departing view, but
// an un-laid-out view reports {0,0,0,0} from smoothClipCurrentPresentation and
// must never DEFINE the re-latch start — the resumed animation would crawl out
// of a fully collapsed clip. Same filter canonicalFrozenPresentation applies.
- (void)testRelatchFreezeIgnoresAnUnlaidOutDepartingParticipant {
  constexpr uint64_t driverId = 9031;
  UIWindow *window = TestWindow();
  SmoothClipView *displayable =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  SmoothClipView *unlaidOut = [[SmoothClipView alloc] initWithFrame:CGRectZero];
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  smoothclip::registerView(driverId, displayable, initial);
  smoothclip::registerView(driverId, unlaidOut, initial);
  smoothclip::animateTiming(driverId, {true, initial}, target, timing);

  // The rendering host leaves the window without unregistering (a reparent),
  // so nothing is displayable while both are still registered participants.
  [displayable removeFromSuperview];
  smoothclip::unregisterView(driverId, unlaidOut);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));

  // Drop the laid-out survivor too, so canonicalFrozenPresentation has no
  // joinable view left to override with and must report the stored start.
  smoothclip::unregisterView(driverId, displayable);
  const smoothclip::Presentation frozen =
      smoothclip::beginInteraction(driverId);
  // Unguarded, the freeze adopted unlaidOut's {0,0,0,0} as the latch start.
  XCTAssertGreaterThanOrEqual(frozen.clip.width, initial.clip.width);
  XCTAssertGreaterThanOrEqual(frozen.clip.height, initial.clip.height);

  smoothclip::destroyDriver(driverId);
}

// Two installed hosts give Core Animation two real delegates. Detaching both
// re-latches the run; after one host resumes under the SAME animation id, its
// old delegate must still be generation-invalidated. An id check alone cannot
// distinguish it from the resumed delegate and would complete the new run.
- (void)testLateAnimationCallbackCannotCompleteARelatchedAnimation {
  constexpr uint64_t driverId = 9032;
  int completionCount = 0;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver, int32_t, bool) {
        if (completedDriver == driverId) completionCount += 1;
      });
  UIWindow *window = TestWindow();
  SmoothClipView *first =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  SmoothClipView *second =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  [first setValue:@(driverId) forKey:@"driverId"];
  [second setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  smoothclip::registerView(driverId, first, initial);
  smoothclip::registerView(driverId, second, initial);
  const int32_t animationId =
      smoothclip::animateTiming(driverId, {true, initial}, target, timing);
  XCTAssertGreaterThan(animationId, 0);
  id<CAAnimationDelegate> staleDelegate =
      [second valueForKey:@"animationDelegate"];
  XCTAssertNotNil(staleDelegate);

  // The first detach suspends one installed participant; the second removes
  // the last displayable host and re-latches the canonical remainder.
  [first removeFromSuperview];
  [second removeFromSuperview];
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  XCTAssertEqual(completionCount, 0);

  // Resume second under the same id, then deliver the callback retained from
  // its pre-latch CA group. Without delegate invalidation it is accepted as
  // the current participant and completes the resumed run.
  [window addSubview:second];
  UIView *container = [second valueForKey:@"clipContainer"];
  XCTAssertNotNil([container.layer animationForKey:@"smoothClip.geometry"]);
  [staleDelegate animationDidStop:[CAAnimation animation] finished:NO];
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  XCTAssertEqual(completionCount, 0);

  smoothclip::cancelAnimation(driverId, 0, false);
  XCTAssertEqual(completionCount, 1);
  smoothclip::unregisterView(driverId, first);
  smoothclip::unregisterView(driverId, second);
  [first setValue:@0 forKey:@"driverId"];
  [second setValue:@0 forKey:@"driverId"];
  smoothclip::clearCompletionCallback((__bridge const void *)self);
  smoothclip::destroyDriver(driverId);
}

// cancelAnimation(useTarget) against a HELD latch must apply the target to the
// registered hosts itself. A latch never dispatched, so every participant still
// has _activeAnimationId == 0 and smoothClipCancelAnimationUsingTarget
// early-returns: state.latest reported the target while the layer still showed
// the pre-animation geometry, and nothing re-applied it. Android's
// cancelAnimation always fans the result out; this is that parity.
- (void)testCancelToTargetAppliesTheTargetWhenTheAnimationWasLatched {
  constexpr uint64_t driverId = 9033;
  // Laid out but NOT in a window: cannot display, so the animation latches
  // instead of dispatching to the layer.
  SmoothClipView *host =
      [[SmoothClipView alloc] initWithFrame:CGRectMake(0, 0, 120, 120)];
  facebook::react::LayoutMetrics metrics;
  metrics.frame = facebook::react::Rect{
      facebook::react::Point{0, 0}, facebook::react::Size{120, 120}};
  [host updateLayoutMetrics:metrics
           oldLayoutMetrics:facebook::react::LayoutMetrics{}];
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  smoothclip::registerView(driverId, host, initial);
  smoothclip::animateTiming(driverId, {true, initial}, target, timing);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  UIView *container = [host valueForKey:@"clipContainer"];
  XCTAssertNil([container.layer animationForKey:@"smoothClip.geometry"]);

  const smoothclip::CancelResult result =
      smoothclip::cancelAnimation(driverId, 0, true);
  XCTAssertTrue(result.handled);
  XCTAssertEqual(result.presentation.clip.width, target.clip.width);
  // The layer, not just state.latest: unguarded this stayed at `initial`,
  // leaving the registry and the screen disagreeing with nothing to fix it.
  XCTAssertEqualWithAccuracy(
      container.layer.bounds.size.width, target.clip.width, 1e-6);
  XCTAssertEqualWithAccuracy(
      container.layer.bounds.size.height, target.clip.height, 1e-6);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));

  smoothclip::unregisterView(driverId, host);
  smoothclip::destroyDriver(driverId);
}

// Re-latching moved from `participants.empty()` to displayability, which
// dropped the case where the last participant UNREGISTERS while a registered
// host can still display. viewAnimationDidStop is the only other exhaustion
// path and never runs for a departing view, so the animation hung forever: no
// completion, ownership stuck on Native, every declarative delivery dropped.
- (void)testUnregisteringTheLastParticipantCompletesWhileAPeerStillDisplays {
  constexpr uint64_t driverId = 9034;
  int completionCount = 0;
  BOOL completedFinished = YES;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver, int32_t, bool finished) {
        if (completedDriver != driverId) return;
        completionCount += 1;
        completedFinished = finished;
      });
  UIWindow *window = TestWindow();
  SmoothClipView *first = DisplayableView(window, CGRectMake(0, 0, 120, 120));
  SmoothClipView *second = DisplayableView(window, CGRectMake(0, 0, 120, 120));
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  smoothclip::registerView(driverId, first, initial);
  smoothclip::registerView(driverId, second, initial);
  const int32_t animationId =
      smoothclip::animateTiming(driverId, {true, initial}, target, timing);

  // `second` reports its stop early. With a spring this is ordinary rather
  // than contrived: 'inherit' resolves per view, and
  // springSettlingDurationWithVelocity turns that into a per-view duration.
  smoothclip::viewAnimationDidStop(driverId, animationId, second, true);
  XCTAssertEqual(completionCount, 0);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));

  // The remaining participant leaves while `second` is still registered and
  // displayable, so the displayability branch correctly does not fire — and
  // before the fix nothing else did either.
  smoothclip::unregisterView(driverId, first);
  XCTAssertEqual(completionCount, 1);
  XCTAssertFalse(completedFinished);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));

  smoothclip::unregisterView(driverId, second);
  smoothclip::clearCompletionCallback((__bridge const void *)self);
  smoothclip::destroyDriver(driverId);
}

// A detached view has no CA delegate that can ever report a stop. It must not
// become a completion participant until its pending install actually joins.
- (void)testDeferredPeerCannotHoldCompletionAfterVisibleHostFinishes {
  constexpr uint64_t driverId = 9035;
  int completionCount = 0;
  BOOL completedFinished = NO;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver, int32_t, bool finished) {
        if (completedDriver != driverId) return;
        completionCount += 1;
        completedFinished = finished;
      });
  UIWindow *window = TestWindow();
  SmoothClipView *visible =
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

  smoothclip::registerView(driverId, visible, initial);
  smoothclip::registerView(driverId, deferred, initial);
  const int32_t animationId = smoothclip::animateTiming(
      driverId, {true, initial}, target, timing);
  UIView *deferredContainer = [deferred valueForKey:@"clipContainer"];
  XCTAssertNil([deferredContainer.layer animationForKey:@"smoothClip.geometry"]);

  smoothclip::viewAnimationDidStop(driverId, animationId, visible, true);
  XCTAssertEqual(completionCount, 1);
  XCTAssertTrue(completedFinished);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));
  XCTAssertEqualWithAccuracy(
      deferredContainer.layer.bounds.size.width, target.clip.width, 1e-6);

  // Neither a stale callback nor later displayability may resurrect or
  // complete the retired id again.
  smoothclip::viewAnimationDidStop(driverId, animationId, deferred, true);
  [window addSubview:deferred];
  XCTAssertNil([deferredContainer.layer animationForKey:@"smoothClip.geometry"]);
  XCTAssertEqual(completionCount, 1);

  smoothclip::unregisterView(driverId, visible);
  smoothclip::unregisterView(driverId, deferred);
  smoothclip::clearCompletionCallback((__bridge const void *)self);
  smoothclip::destroyDriver(driverId);
}

// Animation ids must survive an erased registry incarnation. Otherwise a CA
// stop queued by the old view can match the replay's new id and complete it.
- (void)testDelayedStopCannotMatchAnimationAfterDriverRecreation {
  constexpr uint64_t driverId = 9036;
  UIWindow *window = TestWindow();
  SmoothClipView *view =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  smoothclip::registerView(driverId, view, initial);
  const int32_t oldId = smoothclip::animateTiming(
      driverId, {true, initial}, target, timing);
  smoothclip::unregisterView(driverId, view);
  smoothclip::destroyDriver(driverId);

  smoothclip::registerView(driverId, view, initial);
  const int32_t newId = smoothclip::animateTiming(
      driverId, {true, initial}, target, timing);
  XCTAssertNotEqual(oldId, newId);
  smoothclip::viewAnimationDidStop(driverId, oldId, view, false);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));

  smoothclip::cancelAnimation(driverId, newId, false);
  smoothclip::unregisterView(driverId, view);
  smoothclip::destroyDriver(driverId);
}

// The headless suite has no live presentation layer, so it cannot assert the
// frozen mid-flight geometry. It can still pin the analytic velocity carried
// into the resumed CA spring; pure tests cover the physical continuation math.
- (void)testRelatchedSpringCarriesAnalyticVelocityIntoTheResumedRun {
  constexpr uint64_t driverId = 9037;
  UIWindow *window = TestWindow();
  SmoothClipView *view =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::SpringAnimation spring{1, 180, 18, 2, false, 2};

  smoothclip::registerView(driverId, view, initial);
  smoothclip::animateSpring(driverId, {true, initial}, target, spring);
  usleep(16000);
  smoothclip::unregisterView(driverId, view);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));

  SmoothClipView *resumed =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  smoothclip::registerView(driverId, resumed, initial);
  UIView *container = [resumed valueForKey:@"clipContainer"];
  CAAnimationGroup *group = (CAAnimationGroup *)[container.layer
      animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(group);
  const double velocity =
      ((CASpringAnimation *)group.animations.firstObject).initialVelocity;
  XCTAssertTrue(std::isfinite(velocity));
  XCTAssertGreaterThan(std::fabs(velocity), 0.1);

  smoothclip::cancelAnimation(driverId, 0, false);
  smoothclip::unregisterView(driverId, resumed);
  smoothclip::destroyDriver(driverId);
}

// A host mounting during an active spring must inherit the rendering peer's
// current physical state, not replay the request's original launch velocity.
- (void)testMidflightSpringJoinCarriesTheCanonicalViewsCurrentVelocity {
  constexpr uint64_t driverId = 9039;
  UIWindow *window = TestWindow();
  SmoothClipView *first =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::SpringAnimation spring{1, 180, 18, 2, false, 2};

  smoothclip::registerView(driverId, first, initial);
  smoothclip::animateSpring(driverId, {true, initial}, target, spring);
  usleep(16000);

  SmoothClipView *joined =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  smoothclip::registerView(driverId, joined, initial);
  const double expected = [first smoothClipSpringContinuationVelocity];
  UIView *container = [joined valueForKey:@"clipContainer"];
  CAAnimationGroup *group = (CAAnimationGroup *)[container.layer
      animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(group);
  const double installed =
      ((CASpringAnimation *)group.animations.firstObject).initialVelocity;
  // Tolerance sized for CI scheduling: the continuation changes ~134 s⁻¹, so
  // 1.0 tolerates ~7 ms of preemption between the install and the reference
  // read while staying well inside the >0.5 launch-velocity separation below.
  XCTAssertEqualWithAccuracy(installed, expected, 1.0);
  XCTAssertGreaterThan(std::fabs(installed - spring.initialVelocity), 0.5);

  smoothclip::cancelAnimation(driverId, 0, false);
  smoothclip::unregisterView(driverId, first);
  smoothclip::unregisterView(driverId, joined);
  smoothclip::destroyDriver(driverId);
}

// The residual timing curve, not just the duration, must be installed after a
// re-latch. Inspecting CA's copied timing function works without a render
// server and mutation-fails if unregisterView keeps the original controls.
- (void)testRelatchedTimingInstallsTheExactRemainingBezierSegment {
  constexpr uint64_t driverId = 9038;
  UIWindow *window = TestWindow();
  SmoothClipView *view =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{1000, 0.42, 0, 0.58, 1, 2};

  smoothclip::registerView(driverId, view, initial);
  smoothclip::animateTiming(driverId, {true, initial}, target, timing);
  usleep(50000);
  smoothclip::unregisterView(driverId, view);

  SmoothClipView *resumed =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  smoothclip::registerView(driverId, resumed, initial);
  UIView *container = [resumed valueForKey:@"clipContainer"];
  CAAnimationGroup *group = (CAAnimationGroup *)[container.layer
      animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(group);
  const double cutoff = 1 - group.duration;
  const smoothclip::TimingRemainder expected =
      smoothclip::timingRemainder(timing, cutoff);
  CABasicAnimation *bounds = (CABasicAnimation *)group.animations.firstObject;
  float first[2] = {};
  float second[2] = {};
  [bounds.timingFunction getControlPointAtIndex:1 values:first];
  [bounds.timingFunction getControlPointAtIndex:2 values:second];
  XCTAssertEqualWithAccuracy(
      first[0], expected.animation.controlPoint1X, 2e-3);
  XCTAssertEqualWithAccuracy(
      first[1], expected.animation.controlPoint1Y, 2e-3);
  XCTAssertEqualWithAccuracy(
      second[0], expected.animation.controlPoint2X, 2e-3);
  XCTAssertEqualWithAccuracy(
      second[1], expected.animation.controlPoint2Y, 2e-3);

  smoothclip::cancelAnimation(driverId, 0, false);
  smoothclip::unregisterView(driverId, resumed);
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

// A held latch has no installed participants, so a view leaving while it is
// held must not poison the eventual natural completion: the run that later
// starts and finishes cleanly reports finished:true. Contract pin for the
// participant-gated `finished` rule; Android mirrors it with explicit
// deferred/active/suspended participation markers.
- (void)testLatchSurvivingAnUnregisterStillCompletesFinished {
  constexpr uint64_t driverId = 9040;
  int completionCount = 0;
  BOOL completedFinished = NO;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver, int32_t, bool finished) {
        if (completedDriver != driverId) return;
        completionCount += 1;
        completedFinished = finished;
      });
  SmoothClipView *never = [[SmoothClipView alloc] initWithFrame:CGRectZero];
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  smoothclip::registerView(driverId, never, initial);
  const int32_t animationId =
      smoothclip::animateTiming(driverId, {true, initial}, target, timing);
  XCTAssertGreaterThan(animationId, 0);
  smoothclip::unregisterView(driverId, never);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  XCTAssertEqual(completionCount, 0);

  UIWindow *window = TestWindow();
  SmoothClipView *host = DisplayableView(window, CGRectMake(0, 0, 120, 120));
  smoothclip::registerView(driverId, host, initial);
  smoothclip::viewAnimationDidStop(driverId, animationId, host, true);
  XCTAssertEqual(completionCount, 1);
  XCTAssertTrue(completedFinished);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));

  smoothclip::unregisterView(driverId, host);
  smoothclip::clearCompletionCallback((__bridge const void *)self);
  smoothclip::destroyDriver(driverId);
}

// cancel-to-target of a HELD latch applies the target to the hosts but must
// not enter the 'inherit' velocity history: a jump to the target is not
// interactive motion, and Android's cancel fan-out records nothing. Unfixed,
// the animate→cancel sample pair (16 ms apart here) reads as real motion and
// launches the next inherited spring with a phantom velocity.
- (void)testLatchedCancelToTargetDoesNotEnterTheInheritHistory {
  constexpr uint64_t driverId = 9041;
  UIWindow *window = TestWindow();
  // Laid out but detached: velocity samples record (hasLayout) while any
  // animation can only latch (no window).
  SmoothClipView *host =
      [[SmoothClipView alloc] initWithFrame:CGRectMake(0, 0, 120, 120)];
  facebook::react::LayoutMetrics metrics;
  metrics.frame = facebook::react::Rect{
      facebook::react::Point{0, 0}, facebook::react::Size{120, 120}};
  [host updateLayoutMetrics:metrics
           oldLayoutMetrics:facebook::react::LayoutMetrics{}];
  [host setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  smoothclip::registerView(driverId, host, initial);
  smoothclip::animateTiming(driverId, {true, initial}, target, timing);
  // The gap sits between the animate call's interactive-start sample and the
  // cancel: a mutated recording cancel would then ROTATE a fresh pair instead
  // of coalescing into the previous sample, so the inherit below turns
  // non-zero and the revert is caught.
  usleep(16000); // clear of the 4 ms same-frame coalesce window
  smoothclip::cancelAnimation(driverId, 0, true);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));

  [window addSubview:host];
  // reduceMotion 'never' so the spring installs even on CI machines; the
  // target is deliberately NOT the cancelled latch's target so a phantom
  // sample pair would project onto a non-zero remaining trajectory.
  const smoothclip::SpringAnimation spring{1, 180, 18, 0, true, 2};
  const int32_t animationId = smoothclip::animateSpring(
      driverId, {false, initial},
      Presentation(0, 0, 160, 160, 8, -40, -60), spring);
  XCTAssertGreaterThan(animationId, 0);

  UIView *container = [host valueForKey:@"clipContainer"];
  CAAnimationGroup *group = (CAAnimationGroup *)[container.layer
      animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(group);
  XCTAssertEqualWithAccuracy(
      ((CASpringAnimation *)group.animations.firstObject).initialVelocity,
      0,
      1e-9);

  smoothclip::cancelAnimation(driverId, 0, false);
  smoothclip::unregisterView(driverId, host);
  smoothclip::destroyDriver(driverId);
}

- (void)testReduceMotionFinalizationDoesNotEnterTheInheritHistory {
  constexpr uint64_t driverId = 9047;
  UIWindow *window = TestWindow();
  SmoothClipView *view = DisplayableView(window, CGRectMake(0, 0, 180, 180));
  const smoothclip::Presentation initial = Presentation(0, 0, 40, 40, 20);
  const smoothclip::Presentation dragged = Presentation(0, 0, 50, 50, 18);
  const smoothclip::Presentation finalized = Presentation(0, 0, 100, 100, 12);
  const smoothclip::Presentation target = Presentation(0, 0, 160, 160, 8);
  smoothclip::registerView(driverId, view, initial);

  // Build a real interactive pair, then let its latest sample become stale.
  smoothclip::setPresentation(driverId, initial, true);
  usleep(16000);
  smoothclip::setPresentation(driverId, dragged, true);
  usleep(120000);

  // reduceMotion=always instant-finalizes. If this model-layer write were
  // recorded, it would refresh the stale history and manufacture a large
  // finalized→target inherited velocity below.
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 1};
  smoothclip::animateTiming(driverId, {false, initial}, finalized, timing);
  const smoothclip::SpringAnimation spring{1, 180, 18, 0, true, 2};
  smoothclip::animateSpring(driverId, {false, initial}, target, spring);

  UIView *container = [view valueForKey:@"clipContainer"];
  CAAnimationGroup *group = (CAAnimationGroup *)[container.layer
      animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(group);
  XCTAssertEqualWithAccuracy(
      ((CASpringAnimation *)group.animations.firstObject).initialVelocity,
      0,
      1e-9);

  smoothclip::cancelAnimation(driverId, 0, false);
  smoothclip::unregisterView(driverId, view);
  smoothclip::destroyDriver(driverId);
}

- (void)testBackgroundTimingRebasesLateJoinAndSuspendedCompletion {
  constexpr uint64_t driverId = 9042;
  int completionCount = 0;
  BOOL completedFinished = YES;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver, int32_t, bool finished) {
        if (completedDriver != driverId) return;
        completionCount += 1;
        completedFinished = finished;
      });
  UIWindow *window = TestWindow();
  SmoothClipView *first = DisplayableView(window, CGRectMake(0, 0, 120, 120));
  const smoothclip::Presentation initial = Presentation(0, 0, 40, 40, 20);
  const smoothclip::Presentation target = Presentation(0, 0, 100, 100, 12);
  // Long duration + wide bounds: the assertions must separate three
  // behaviors (trimmed ≈ 0.8 s, untrimmed = 0.9 s, unrebased ≈ 0.3 s after
  // the 0.4 s background hold) while tolerating ~250 ms of CI scheduling
  // overshoot in the pre-background sleep.
  const smoothclip::TimingAnimation timing{900, 0.42, 0, 0.58, 1, 2};
  smoothclip::registerView(driverId, first, initial);
  const int32_t animationId = smoothclip::animateTiming(
      driverId, {true, initial}, target, timing);
  usleep(100000);

  smoothclip::applicationWillResignActive();
  UIView *firstContainer = [first valueForKey:@"clipContainer"];
  XCTAssertNil([firstContainer.layer animationForKey:@"smoothClip.geometry"]);
  usleep(400000);
  smoothclip::applicationDidBecomeActive();
  CAAnimationGroup *resumed = (CAAnimationGroup *)[firstContainer.layer
      animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(resumed);
  XCTAssertGreaterThan(resumed.duration, 0.55);
  XCTAssertLessThan(resumed.duration, 0.85);

  SmoothClipView *late = DisplayableView(window, CGRectMake(0, 0, 120, 120));
  smoothclip::registerView(driverId, late, initial);
  UIView *lateContainer = [late valueForKey:@"clipContainer"];
  CAAnimationGroup *joined = (CAAnimationGroup *)[lateContainer.layer
      animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(joined);
  XCTAssertLessThanOrEqual(joined.duration, resumed.duration);

  smoothclip::unregisterView(driverId, first);
  smoothclip::viewAnimationDidStop(driverId, animationId, late, true);
  XCTAssertEqual(completionCount, 1);
  XCTAssertFalse(completedFinished);
  smoothclip::unregisterView(driverId, late);
  smoothclip::clearCompletionCallback((__bridge const void *)self);
  smoothclip::destroyDriver(driverId);
}

- (void)testSoleHostDetachAndReattachCanStillFinishTrue {
  constexpr uint64_t driverId = 9045;
  int completionCount = 0;
  BOOL completedFinished = NO;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver, int32_t, bool finished) {
        if (completedDriver != driverId) return;
        completionCount += 1;
        completedFinished = finished;
      });
  UIWindow *window = TestWindow();
  SmoothClipView *view = DisplayableView(window, CGRectMake(0, 0, 120, 120));
  [view setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation initial = Presentation(0, 0, 40, 40, 20);
  const smoothclip::Presentation target = Presentation(0, 0, 100, 100, 12);
  const smoothclip::TimingAnimation timing{300, 0.42, 0, 0.58, 1, 2};
  smoothclip::registerView(driverId, view, initial);
  const int32_t animationId = smoothclip::animateTiming(
      driverId, {true, initial}, target, timing);

  [view removeFromSuperview];
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  [window addSubview:view];
  UIView *container = [view valueForKey:@"clipContainer"];
  XCTAssertNotNil([container.layer animationForKey:@"smoothClip.geometry"]);
  smoothclip::viewAnimationDidStop(driverId, animationId, view, true);
  XCTAssertEqual(completionCount, 1);
  XCTAssertTrue(completedFinished);

  smoothclip::unregisterView(driverId, view);
  [view setValue:@0 forKey:@"driverId"];
  smoothclip::clearCompletionCallback((__bridge const void *)self);
  smoothclip::destroyDriver(driverId);
}

- (void)testUnresolvedSuspendedHostMakesCompletionFalse {
  constexpr uint64_t driverId = 9046;
  int completionCount = 0;
  BOOL completedFinished = YES;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver, int32_t, bool finished) {
        if (completedDriver != driverId) return;
        completionCount += 1;
        completedFinished = finished;
      });
  UIWindow *window = TestWindow();
  SmoothClipView *suspended =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  SmoothClipView *active =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  [suspended setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation initial = Presentation(0, 0, 40, 40, 20);
  const smoothclip::Presentation target = Presentation(0, 0, 100, 100, 12);
  const smoothclip::TimingAnimation timing{300, 0.42, 0, 0.58, 1, 2};
  smoothclip::registerView(driverId, suspended, initial);
  smoothclip::registerView(driverId, active, initial);
  const int32_t animationId = smoothclip::animateTiming(
      driverId, {true, initial}, target, timing);

  [suspended removeFromSuperview];
  smoothclip::viewAnimationDidStop(driverId, animationId, active, true);
  XCTAssertEqual(completionCount, 1);
  XCTAssertFalse(completedFinished);

  smoothclip::unregisterView(driverId, suspended);
  [suspended setValue:@0 forKey:@"driverId"];
  smoothclip::unregisterView(driverId, active);
  smoothclip::clearCompletionCallback((__bridge const void *)self);
  smoothclip::destroyDriver(driverId);
}

- (void)testBackgroundKeyframesResumeFromTrimmedRemainder {
  constexpr uint64_t driverId = 9043;
  UIWindow *window = TestWindow();
  SmoothClipView *view = DisplayableView(window, CGRectMake(0, 0, 120, 120));
  const smoothclip::Presentation initial = Presentation(0, 0, 40, 40, 20);
  const smoothclip::Presentation middle = Presentation(0, 0, 70, 70, 16);
  const smoothclip::Presentation target = Presentation(0, 0, 100, 100, 12);
  smoothclip::registerView(driverId, view, initial);
  // Bounds sized like the timing twin above: trimmed ≈ 0.8 s vs untrimmed
  // 0.9 s vs unrebased ≈ 0.3 s, with ~250 ms of scheduling headroom.
  smoothclip::animateKeyframes(
      driverId,
      {true, initial},
      target,
      900,
      {{0, initial}, {0.5, middle}, {1, target}},
      2);
  usleep(100000);
  smoothclip::applicationWillResignActive();
  usleep(400000);
  smoothclip::applicationDidBecomeActive();

  UIView *container = [view valueForKey:@"clipContainer"];
  CAAnimationGroup *group = (CAAnimationGroup *)[container.layer
      animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(group);
  XCTAssertGreaterThan(group.duration, 0.55);
  XCTAssertLessThan(group.duration, 0.85);
  CAKeyframeAnimation *bounds = (CAKeyframeAnimation *)group.animations.firstObject;
  XCTAssertEqualWithAccuracy(bounds.keyTimes.firstObject.doubleValue, 0, 1e-12);
  XCTAssertEqualWithAccuracy(bounds.keyTimes.lastObject.doubleValue, 1, 1e-12);

  smoothclip::cancelAnimation(driverId, 0, false);
  smoothclip::unregisterView(driverId, view);
  smoothclip::destroyDriver(driverId);
}

- (void)testBackgroundSpringResumesWithSampledContinuationVelocity {
  constexpr uint64_t driverId = 9044;
  UIWindow *window = TestWindow();
  SmoothClipView *view = DisplayableView(window, CGRectMake(0, 0, 120, 120));
  const smoothclip::Presentation initial = Presentation(0, 0, 40, 40, 20);
  const smoothclip::Presentation target = Presentation(0, 0, 100, 100, 12);
  const smoothclip::SpringAnimation spring{1, 180, 18, 2, false, 2};
  smoothclip::registerView(driverId, view, initial);
  smoothclip::animateSpring(driverId, {true, initial}, target, spring);
  usleep(30000);
  const double expected = [view smoothClipSpringContinuationVelocity];
  smoothclip::applicationWillResignActive();
  usleep(100000);
  smoothclip::applicationDidBecomeActive();

  UIView *container = [view valueForKey:@"clipContainer"];
  CAAnimationGroup *group = (CAAnimationGroup *)[container.layer
      animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(group);
  const double installed =
      ((CASpringAnimation *)group.animations.firstObject).initialVelocity;
  // Wide enough for ~11 ms of scheduler noise between the reference read and
  // the resign (the continuation moves ~134 s⁻¹); still separated from the
  // launch velocity by the assertion below.
  XCTAssertEqualWithAccuracy(installed, expected, 1.5);
  XCTAssertGreaterThan(std::fabs(installed - spring.initialVelocity), 0.5);

  smoothclip::cancelAnimation(driverId, 0, false);
  smoothclip::unregisterView(driverId, view);
  smoothclip::destroyDriver(driverId);
}

// A deferred install completed by this view's own FIRST LAYOUT: the join runs
// inside the layout pass, and the pass's pending-install guard below it must
// return without touching the joined group. Falling through would recompute a
// zero remainder from this view's never-installed local clock and reinstall
// from its zero entry rect.
- (void)testDeferredPeerFirstLayoutJoinSurvivesTheRelayoutPass {
  constexpr uint64_t driverId = 9065;
  UIWindow *window = TestWindow();
  SmoothClipView *peer = DisplayableView(window, CGRectMake(0, 0, 120, 120));
  // Attached but never laid out: registers, then defers its install while the
  // peer keeps the animation running.
  SmoothClipView *pending =
      [[SmoothClipView alloc] initWithFrame:CGRectMake(0, 0, 120, 120)];
  [pending setValue:@(driverId) forKey:@"driverId"];
  [window addSubview:pending];
  const smoothclip::Presentation initial = Presentation(0, 0, 40, 40, 20);
  const smoothclip::Presentation target = Presentation(0, 0, 100, 100, 12);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};
  smoothclip::registerView(driverId, peer, initial);
  smoothclip::registerView(driverId, pending, initial);
  smoothclip::animateTiming(driverId, {true, initial}, target, timing);
  UIView *container = [pending valueForKey:@"clipContainer"];
  XCTAssertNil([container.layer animationForKey:@"smoothClip.geometry"]);

  facebook::react::LayoutMetrics metrics;
  metrics.frame = facebook::react::Rect{
      facebook::react::Point{0, 0}, facebook::react::Size{120, 120}};
  [pending updateLayoutMetrics:metrics
              oldLayoutMetrics:facebook::react::LayoutMetrics{}];

  CAAnimationGroup *group = (CAAnimationGroup *)[container.layer
      animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(group);
  XCTAssertGreaterThan(group.duration, 0);
  CABasicAnimation *bounds = (CABasicAnimation *)group.animations.firstObject;
  const CGRect joinedFrom = [bounds.fromValue CGRectValue];
  // Joined from the rendering peer's live presentation — never from this
  // host's own zero rect.
  XCTAssertEqualWithAccuracy(joinedFrom.size.width, 100, 1e-6);

  smoothclip::cancelAnimation(driverId, 0, false);
  smoothclip::unregisterView(driverId, peer);
  smoothclip::unregisterView(driverId, pending);
  [pending setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

// The active-state cache is process-global, so its observer must be too. A
// transition delivered while no SmoothClipView is alive (the last host
// unmounted during inactivity) must still land — with view-held observers the
// flag stayed stale forever and every later animation latched against it.
- (void)testApplicationStateSurvivesTransitionsDeliveredWithoutLiveViews {
  constexpr uint64_t driverId = 9060;
  (void)smoothclip::applicationIsActive();
  @autoreleasepool {
    SmoothClipView *transient =
        [[SmoothClipView alloc] initWithFrame:CGRectMake(0, 0, 60, 60)];
    (void)transient;
    [NSNotificationCenter.defaultCenter
        postNotificationName:UIApplicationWillResignActiveNotification
                      object:nil];
    XCTAssertFalse(smoothclip::applicationIsActive());
  }
  // Anything a view registered died with it; only a registry-owned observer
  // can see the reactivation.
  [NSNotificationCenter.defaultCenter
      postNotificationName:UIApplicationDidBecomeActiveNotification
                    object:nil];
  XCTAssertTrue(smoothclip::applicationIsActive());

  UIWindow *window = TestWindow();
  SmoothClipView *host = DisplayableView(window, CGRectMake(0, 0, 120, 120));
  const smoothclip::Presentation initial = Presentation(0, 0, 40, 40, 20);
  const smoothclip::Presentation target = Presentation(0, 0, 100, 100, 12);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};
  smoothclip::registerView(driverId, host, initial);
  smoothclip::animateTiming(driverId, {true, initial}, target, timing);
  UIView *container = [host valueForKey:@"clipContainer"];
  // Starts immediately: the recovered flag admits the displayable install.
  XCTAssertNotNil([container.layer animationForKey:@"smoothClip.geometry"]);

  smoothclip::cancelAnimation(driverId, 0, false);
  smoothclip::unregisterView(driverId, host);
  smoothclip::destroyDriver(driverId);
}

// A sole RUNNING host whose relayout collapses to zero size fails the
// joinable filter, but its clip layer still holds real mid-flight geometry —
// the re-latch must freeze there, not at state.latest (the target).
- (void)testZeroSizedRelayoutOfTheSoleRunningHostRelatchesFromItsFrozenPresentation {
  constexpr uint64_t driverId = 9061;
  int completionCount = 0;
  BOOL completedFinished = NO;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver, int32_t, bool finished) {
        if (completedDriver != driverId) return;
        completionCount += 1;
        completedFinished = finished;
      });
  UIWindow *window = TestWindow();
  SmoothClipView *host = DisplayableView(window, CGRectMake(0, 0, 120, 120));
  [host setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation initial = Presentation(0, 0, 40, 40, 20);
  const smoothclip::Presentation target = Presentation(0, 0, 100, 100, 12);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};
  smoothclip::registerView(driverId, host, initial);
  const int32_t animationId = smoothclip::animateTiming(
      driverId, {true, initial}, target, timing);
  XCTAssertGreaterThan(animationId, 0);

  // Headless stand-in for the mid-flight presentation layer: seed the model
  // layer with a value strictly between start and target; the freeze reads it
  // through the presentation-layer fallback.
  UIView *container = [host valueForKey:@"clipContainer"];
  container.layer.bounds = CGRectMake(0, 0, 70, 70);
  container.layer.position = CGPointMake(35, 35);
  container.layer.cornerRadius = 16;

  facebook::react::LayoutMetrics zeroMetrics;
  zeroMetrics.frame = facebook::react::Rect{
      facebook::react::Point{0, 0}, facebook::react::Size{0, 0}};
  [host updateLayoutMetrics:zeroMetrics
           oldLayoutMetrics:facebook::react::LayoutMetrics{}];
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  XCTAssertNil([container.layer animationForKey:@"smoothClip.geometry"]);
  // Held, not ticking: well past the original duration.
  usleep(300000);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));

  facebook::react::LayoutMetrics metrics;
  metrics.frame = facebook::react::Rect{
      facebook::react::Point{0, 0}, facebook::react::Size{120, 120}};
  [host updateLayoutMetrics:metrics oldLayoutMetrics:zeroMetrics];

  CAAnimationGroup *group = (CAAnimationGroup *)[container.layer
      animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(group);
  CABasicAnimation *bounds = (CABasicAnimation *)group.animations.firstObject;
  const CGRect resumedFrom = [bounds.fromValue CGRectValue];
  // The frozen mid-flight value — not the target the un-joinable fallback
  // used to produce.
  XCTAssertEqualWithAccuracy(resumedFrom.size.width, 70, 1e-6);

  smoothclip::viewAnimationDidStop(driverId, animationId, host, true);
  XCTAssertEqual(completionCount, 1);
  XCTAssertTrue(completedFinished);
  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::clearCompletionCallback((__bridge const void *)self);
  smoothclip::destroyDriver(driverId);
}

// The freeze that accompanies a registry re-latch clears _activeAnimationId,
// which happens to keep the relayout rebuild away from its stale local clock
// on the resuming pass. That is a side effect, not a contract. If a host
// enters a layout pass still holding an animation id while that pass's own
// displayability notification resumes the held latch, the rebuild would
// overwrite the fresh install with a remainder measured ACROSS the suspension
// — shorter than the trimmed remainder, possibly zero. The id cannot detect
// this (a resume keeps the animation id), so the view compares its install
// generation. Restore the stale id by hand to simulate the accidental guard
// being absent and pin the invariant directly: the install that happened
// inside the layout pass survives it.
- (void)testResumeInstallInsideALayoutPassSurvivesTheStaleLocalRebuild {
  constexpr uint64_t driverId = 9063;
  UIWindow *window = TestWindow();
  SmoothClipView *host = DisplayableView(window, CGRectMake(0, 0, 120, 120));
  [host setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation initial = Presentation(0, 0, 40, 40, 20);
  const smoothclip::Presentation target = Presentation(0, 0, 100, 100, 12);
  const smoothclip::TimingAnimation timing{600, 0.42, 0, 0.58, 1, 2};
  smoothclip::registerView(driverId, host, initial);
  const int32_t animationId = smoothclip::animateTiming(
      driverId, {true, initial}, target, timing);
  XCTAssertGreaterThan(animationId, 0);

  // Headless stand-in for the mid-flight presentation layer (see the
  // zero-sized relayout test above).
  UIView *container = [host valueForKey:@"clipContainer"];
  container.layer.bounds = CGRectMake(0, 0, 70, 70);
  container.layer.position = CGPointMake(35, 35);
  container.layer.cornerRadius = 16;

  // Let a slice of the curve elapse so the re-latch trims a remainder that is
  // clearly distinguishable from the stale wall-clock arithmetic below.
  usleep(50000);
  facebook::react::LayoutMetrics zeroMetrics;
  zeroMetrics.frame = facebook::react::Rect{
      facebook::react::Point{0, 0}, facebook::react::Size{0, 0}};
  [host updateLayoutMetrics:zeroMetrics
           oldLayoutMetrics:facebook::react::LayoutMetrics{}];
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  // Held, not ticking. The local `_animationStartedAt` is NOT rebased while
  // held, so a stale rebuild on the resuming pass would measure this sleep as
  // consumed duration.
  usleep(300000);

  // Simulate the freeze side-effect being absent: hand the view back the id
  // and kind it held before the suspension. The clocks stay stale — exactly
  // the state a reordering of the freeze would produce.
  [host setValue:@(animationId) forKey:@"activeAnimationId"];
  [host setValue:@1 forKey:@"activeAnimationKind"];

  facebook::react::LayoutMetrics metrics;
  metrics.frame = facebook::react::Rect{
      facebook::react::Point{0, 0}, facebook::react::Size{120, 120}};
  [host updateLayoutMetrics:metrics oldLayoutMetrics:zeroMetrics];

  CAAnimationGroup *group = (CAAnimationGroup *)[container.layer
      animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(group);
  // The registry's trimmed remainder (~550ms of the 600ms curve): the stale
  // rebuild would have re-installed ~250ms or less (600 minus the held wall
  // clock), a full restart would be 600ms.
  XCTAssertGreaterThan(group.duration, 0.35);
  XCTAssertLessThan(group.duration, 0.58);

  smoothclip::viewAnimationDidStop(driverId, animationId, host, true);
  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

// destroyDriver must clear the 'inherit' history: a revived incarnation's
// passive seed would otherwise pair with the dead driver's samples and
// refresh the staleness clock with motion no finger produced.
- (void)testDestroyedDriverDoesNotSeedInheritedVelocityAcrossRevival {
  constexpr uint64_t driverId = 9062;
  UIWindow *window = TestWindow();
  SmoothClipView *host = DisplayableView(window, CGRectMake(0, 0, 180, 180));
  const smoothclip::Presentation first = Presentation(0, 0, 40, 40, 20);
  const smoothclip::Presentation second = Presentation(0, 0, 50, 50, 18);
  const smoothclip::Presentation seed = Presentation(0, 0, 100, 100, 12);
  const smoothclip::Presentation target = Presentation(0, 0, 160, 160, 8);
  smoothclip::registerView(driverId, host, first);

  // A real interactive pair...
  smoothclip::setPresentation(driverId, first, true);
  usleep(16000);
  smoothclip::setPresentation(driverId, second, true);

  // ...must not survive the teardown. The gaps keep every write clear of the
  // 4 ms coalesce window so an un-cleared history would genuinely rotate.
  smoothclip::destroyDriver(driverId); // tombstone: the host stays registered
  usleep(16000);
  smoothclip::setPresentation(driverId, seed, true); // revival seed
  const smoothclip::SpringAnimation spring{1, 180, 18, 0, true, 2};
  const int32_t animationId = smoothclip::animateSpring(
      driverId, {false, seed}, target, spring);
  XCTAssertGreaterThan(animationId, 0);

  UIView *container = [host valueForKey:@"clipContainer"];
  CAAnimationGroup *group = (CAAnimationGroup *)[container.layer
      animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(group);
  XCTAssertEqualWithAccuracy(
      ((CASpringAnimation *)group.animations.firstObject).initialVelocity,
      0,
      1e-9);

  smoothclip::cancelAnimation(driverId, 0, false);
  smoothclip::unregisterView(driverId, host);
  smoothclip::destroyDriver(driverId);
}

// Backgrounding in the window between the curve's last rendered frame and its
// asynchronous didStop must not stamp a fully-rendered run finished:false.
- (void)testResignActiveAfterTheCurveElapsedCompletesFinishedTrue {
  constexpr uint64_t driverId = 9063;
  int completionCount = 0;
  BOOL completedFinished = NO;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver, int32_t, bool finished) {
        if (completedDriver != driverId) return;
        completionCount += 1;
        completedFinished = finished;
      });
  UIWindow *window = TestWindow();
  SmoothClipView *host = DisplayableView(window, CGRectMake(0, 0, 120, 120));
  const smoothclip::Presentation initial = Presentation(0, 0, 40, 40, 20);
  const smoothclip::Presentation target = Presentation(0, 0, 100, 100, 12);
  const smoothclip::TimingAnimation timing{30, 0.42, 0, 0.58, 1, 2};
  smoothclip::registerView(driverId, host, initial);
  smoothclip::animateTiming(driverId, {true, initial}, target, timing);
  // The curve fully elapses; the headless runner never delivers didStop.
  usleep(60000);
  smoothclip::applicationWillResignActive();
  XCTAssertEqual(completionCount, 1);
  XCTAssertTrue(completedFinished);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));

  smoothclip::applicationDidBecomeActive();
  smoothclip::unregisterView(driverId, host);
  smoothclip::clearCompletionCallback((__bridge const void *)self);
  smoothclip::destroyDriver(driverId);
}

// The same race with a host that was ALREADY suspended before the freeze is
// unresolved and must still poison the completion.
- (void)testResignActiveAfterTheCurveElapsedStaysFalseWithAnUnresolvedSuspendedHost {
  constexpr uint64_t driverId = 9064;
  int completionCount = 0;
  BOOL completedFinished = YES;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver, int32_t, bool finished) {
        if (completedDriver != driverId) return;
        completionCount += 1;
        completedFinished = finished;
      });
  UIWindow *window = TestWindow();
  SmoothClipView *suspended =
      DisplayableView(window, CGRectMake(0, 0, 120, 120));
  SmoothClipView *active = DisplayableView(window, CGRectMake(0, 0, 120, 120));
  [suspended setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation initial = Presentation(0, 0, 40, 40, 20);
  const smoothclip::Presentation target = Presentation(0, 0, 100, 100, 12);
  const smoothclip::TimingAnimation timing{30, 0.42, 0, 0.58, 1, 2};
  smoothclip::registerView(driverId, suspended, initial);
  smoothclip::registerView(driverId, active, initial);
  smoothclip::animateTiming(driverId, {true, initial}, target, timing);

  [suspended removeFromSuperview];
  usleep(60000);
  smoothclip::applicationWillResignActive();
  XCTAssertEqual(completionCount, 1);
  XCTAssertFalse(completedFinished);

  smoothclip::applicationDidBecomeActive();
  smoothclip::unregisterView(driverId, suspended);
  [suspended setValue:@0 forKey:@"driverId"];
  smoothclip::unregisterView(driverId, active);
  smoothclip::clearCompletionCallback((__bridge const void *)self);
  smoothclip::destroyDriver(driverId);
}

@end
