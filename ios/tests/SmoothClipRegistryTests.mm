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
- (smoothclip::Presentation)smoothClipCurrentPresentation;
- (void)setClipPresentation:(double)x
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
                 contentScale:(double)contentScale
                shadowEnabled:(BOOL)shadowEnabled
                     shadowRed:(double)shadowRed
                   shadowGreen:(double)shadowGreen
                    shadowBlue:(double)shadowBlue
                   shadowAlpha:(double)shadowAlpha
                 shadowOffsetX:(double)shadowOffsetX
                 shadowOffsetY:(double)shadowOffsetY
              shadowBlurRadius:(double)shadowBlurRadius
              shadowSpreadDistance:(double)shadowSpreadDistance;
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

static smoothclip::Presentation PresentationValue(
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
    double scale,
    smoothclip::Shadow shadow = {}) {
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
  return {geometry, translateX, translateY, scale, shadow};
}

static smoothclip::Shadow BoxShadow(
    double alpha,
    double offsetX,
    double offsetY,
    double blurRadius,
    double spreadDistance = 0,
    double red = 0,
    double green = 0,
    double blue = 0) {
  return {
      true,
      red,
      green,
      blue,
      alpha,
      offsetX,
      offsetY,
      blurRadius,
      spreadDistance};
}

static smoothclip::GroupMotionEntry GroupEntry(
    uint64_t driverId,
    bool hasFrom,
    smoothclip::Presentation from,
    smoothclip::Presentation target) {
  return {driverId, hasFrom, from, target};
}

static std::vector<uint64_t> DriverIds(
    const std::vector<smoothclip::DriverSnapshot> &snapshots) {
  std::vector<uint64_t> result;
  result.reserve(snapshots.size());
  for (const smoothclip::DriverSnapshot &snapshot : snapshots) {
    result.push_back(snapshot.driverId);
  }
  return result;
}

// A view that can actually produce a frame: laid out AND attached to a
// window. Pending animations only start (and CA installs only happen) for
// such views; a mount-time registration from a detached subtree keeps the run
// pending until window attach.
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
  XCTAssertEqual(smoothclip::registeredViewCount(driverId), 1u);

  smoothclip::unregisterView(driverId, first);
  XCTAssertEqual(smoothclip::registeredViewCount(driverId), 0u);
  smoothclip::registerView(driverId, replacement, initial);
  XCTAssertEqual(smoothclip::registeredViewCount(driverId), 1u);
  smoothclip::unregisterView(driverId, first);
  XCTAssertEqual(smoothclip::registeredViewCount(driverId), 1u);
  smoothclip::unregisterView(driverId, replacement);
  XCTAssertEqual(smoothclip::registeredViewCount(driverId), 0u);
  smoothclip::destroyDriver(driverId);
}

- (void)testSecondSimultaneousHostIsRejected {
  constexpr uint64_t driverId = 90011;
  SmoothClipView *first = [[SmoothClipView alloc] initWithFrame:CGRectZero];
  SmoothClipView *second = [[SmoothClipView alloc] initWithFrame:CGRectZero];
  const smoothclip::Presentation initial =
      Presentation(0, 0, 100, 100, 12, -4, -8);

  smoothclip::registerView(driverId, first, initial);
#if DEBUG
  XCTAssertThrowsSpecificNamed(
      smoothclip::registerView(driverId, second, initial),
      NSException,
      NSInternalInconsistencyException);
#else
  smoothclip::registerView(driverId, second, initial);
#endif
  XCTAssertEqual(smoothclip::registeredViewCount(driverId), 1u);

  smoothclip::unregisterView(driverId, first);
  smoothclip::destroyDriver(driverId);
}

- (void)testFabricInitialPropsSeedEveryChannelAndRejectAtomically {
  constexpr uint64_t driverId = 99070;
  constexpr uint64_t rejectedDriverId = 99071;
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  auto initialProps =
      std::make_shared<facebook::react::SmoothClipViewProps>();
  initialProps->driverId = driverId;
  initialProps->initialClipX = 10;
  initialProps->initialClipY = 20;
  initialProps->initialClipWidth = 120;
  initialProps->initialClipHeight = 80;
  initialProps->initialClipTopLeftRadius = 32;
  initialProps->initialClipTopRightRadius = 20;
  initialProps->initialClipBottomRightRadius = 12;
  initialProps->initialClipBottomLeftRadius = 4;
  initialProps->initialClipCurve =
      static_cast<int>(smoothclip::ClipCurve::Continuous);
  initialProps->initialContentTranslateX = 7;
  initialProps->initialContentTranslateY = -9;
  initialProps->initialContentScale = 0.75;
  initialProps->initialClipBoxShadowEnabled = true;
  initialProps->initialClipBoxShadowRed = 0.1;
  initialProps->initialClipBoxShadowGreen = 0.2;
  initialProps->initialClipBoxShadowBlue = 0.3;
  initialProps->initialClipBoxShadowAlpha = 0.4;
  initialProps->initialClipBoxShadowOffsetX = 3;
  initialProps->initialClipBoxShadowOffsetY = 4;
  initialProps->initialClipBoxShadowBlurRadius = 64;
  initialProps->initialClipBoxShadowSpreadDistance = 5;
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
  XCTAssertTrue(initial.shadow.enabled);
  XCTAssertEqualWithAccuracy(initial.shadow.red, 0.1, 1e-9);
  XCTAssertEqualWithAccuracy(initial.shadow.green, 0.2, 1e-9);
  XCTAssertEqualWithAccuracy(initial.shadow.blue, 0.3, 1e-9);
  XCTAssertEqualWithAccuracy(initial.shadow.alpha, 0.4, 1e-9);
  XCTAssertEqualWithAccuracy(initial.shadow.offsetX, 3, 1e-9);
  XCTAssertEqualWithAccuracy(initial.shadow.offsetY, 4, 1e-9);
  XCTAssertEqualWithAccuracy(initial.shadow.blurRadius, 64, 1e-9);
  XCTAssertEqualWithAccuracy(initial.shadow.spreadDistance, 5, 1e-9);

  auto invalidProps =
      std::make_shared<facebook::react::SmoothClipViewProps>();
  invalidProps->driverId = rejectedDriverId;
  invalidProps->initialClipX = 90;
  invalidProps->initialClipY = initialProps->initialClipY;
  invalidProps->initialClipWidth = initialProps->initialClipWidth;
  invalidProps->initialClipHeight = initialProps->initialClipHeight;
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
  invalidProps->initialClipBoxShadowEnabled = initialProps->initialClipBoxShadowEnabled;
  invalidProps->initialClipBoxShadowRed = initialProps->initialClipBoxShadowRed;
  invalidProps->initialClipBoxShadowGreen = initialProps->initialClipBoxShadowGreen;
  invalidProps->initialClipBoxShadowBlue = initialProps->initialClipBoxShadowBlue;
  invalidProps->initialClipBoxShadowAlpha = initialProps->initialClipBoxShadowAlpha;
  invalidProps->initialClipBoxShadowOffsetX = initialProps->initialClipBoxShadowOffsetX;
  invalidProps->initialClipBoxShadowOffsetY = initialProps->initialClipBoxShadowOffsetY;
  invalidProps->initialClipBoxShadowBlurRadius = initialProps->initialClipBoxShadowBlurRadius;
  invalidProps->initialClipBoxShadowSpreadDistance = initialProps->initialClipBoxShadowSpreadDistance;
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

- (void)testFabricCommandRejectsInvalidAggregatesWithoutTakingOwnership {
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));

  // An invalid command must not become authoritative; the next declarative
  // initial presentation must still apply.
  [host setClipPresentation:90
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
                 contentScale:0
                shadowEnabled:NO
                     shadowRed:0
                   shadowGreen:0
                    shadowBlue:0
                   shadowAlpha:1
                 shadowOffsetX:0
                 shadowOffsetY:0
              shadowBlurRadius:0
              shadowSpreadDistance:0];
  auto props = std::make_shared<facebook::react::SmoothClipViewProps>();
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

  [host setClipPresentation:10
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
                 contentScale:0.6
                shadowEnabled:YES
                     shadowRed:0.1
                   shadowGreen:0.2
                    shadowBlue:0.3
                   shadowAlpha:0.4
                 shadowOffsetX:3
                 shadowOffsetY:4
              shadowBlurRadius:64
              shadowSpreadDistance:5];
  const smoothclip::Presentation valid =
      [host smoothClipCurrentPresentation];
  XCTAssertEqualWithAccuracy(valid.clip.x, 10, 1e-9);
  XCTAssertEqualWithAccuracy(valid.clip.topLeftRadius, 32, 1e-9);
  XCTAssertEqualWithAccuracy(valid.clip.bottomLeftRadius, 4, 1e-9);
  XCTAssertEqual(valid.clip.curve, smoothclip::ClipCurve::Continuous);
  XCTAssertEqualWithAccuracy(valid.contentTranslateX, 11, 1e-9);
  XCTAssertEqualWithAccuracy(valid.contentTranslateY, -7, 1e-9);
  XCTAssertEqualWithAccuracy(valid.contentScale, 0.6, 1e-9);
  XCTAssertTrue(valid.shadow.enabled);
  XCTAssertEqualWithAccuracy(valid.shadow.blurRadius, 64, 1e-9);

  [host setClipPresentation:100
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
                 contentScale:1
                shadowEnabled:YES
                     shadowRed:0.1
                   shadowGreen:0.2
                    shadowBlue:0.3
                   shadowAlpha:0.4
                 shadowOffsetX:3
                 shadowOffsetY:4
              shadowBlurRadius:64
              shadowSpreadDistance:5];
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

  [host setClipPresentation:100
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
                 contentScale:1
                shadowEnabled:YES
                     shadowRed:0.1
                   shadowGreen:0.2
                    shadowBlue:0.3
                   shadowAlpha:0.4
                 shadowOffsetX:3
                 shadowOffsetY:4
              shadowBlurRadius:64
              shadowSpreadDistance:5];
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

- (void)testStaticPresentationUsesUnequalMaskAndUnscaledTranslation {
  constexpr uint64_t driverId = 9070;
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  const smoothclip::Presentation initial = Presentation(0, 0, 50, 50, 8);
  const smoothclip::Presentation value = PresentationValue(
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

- (void)testShadowResourcesAreLazyAndFrameUpdatesPreserveShadow {
  constexpr uint64_t driverId = 99079;
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  const smoothclip::Presentation withoutShadow =
      Presentation(0, 0, 100, 100, 16);
  smoothclip::registerView(driverId, host, withoutShadow);

  XCTAssertNil([host valueForKey:@"shadowLayer"]);

  smoothclip::Presentation withShadow = withoutShadow;
  withShadow.shadow = BoxShadow(0.35, 3, 4, 20, 2, 0.1, 0.2, 0.3);
  smoothclip::setPresentation(driverId, withShadow, true);
  XCTAssertNotNil([host valueForKey:@"shadowLayer"]);

  smoothclip::Presentation moved = withShadow;
  moved.clip.x = 12;
  moved.contentTranslateX = 7;
  moved.contentTranslateY = -9;
  smoothclip::setPresentation(driverId, moved, true, false, false);
  const smoothclip::Presentation snapshot =
      smoothclip::snapshotCurrent(driverId);
  XCTAssertEqualWithAccuracy(snapshot.clip.x, 12, 1e-9);
  XCTAssertEqualWithAccuracy(snapshot.contentTranslateX, 7, 1e-9);
  XCTAssertEqualWithAccuracy(snapshot.contentTranslateY, -9, 1e-9);
  XCTAssertTrue(snapshot.shadow.enabled);
  XCTAssertEqualWithAccuracy(snapshot.shadow.alpha, 0.35, 1e-9);
  XCTAssertEqualWithAccuracy(snapshot.shadow.offsetX, 3, 1e-9);
  XCTAssertEqualWithAccuracy(snapshot.shadow.offsetY, 4, 1e-9);
  XCTAssertEqualWithAccuracy(snapshot.shadow.blurRadius, 20, 1e-9);
  XCTAssertEqualWithAccuracy(snapshot.shadow.spreadDistance, 2, 1e-9);

  [host setValue:@(driverId) forKey:@"driverId"];
  smoothclip::Presentation contentOnlyTarget = snapshot;
  contentOnlyTarget.contentTranslateX += 5;
  const smoothclip::TimingAnimation timing{200, 0.42, 0, 0.58, 1, 2};
  const int32_t animationId = smoothclip::animateTiming(
      driverId, {true, snapshot}, contentOnlyTarget, timing);
  XCTAssertGreaterThan(animationId, 0);
  CALayer *shadowLayer = [host valueForKey:@"shadowLayer"];
  XCTAssertNil([shadowLayer animationForKey:@"smoothClip.shadow"]);
  smoothclip::cancelAnimation(driverId, animationId, false);

  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

- (void)testDisappearingShadowCommitsAZeroAlphaTargetModelBeforeRemoval {
  constexpr uint64_t driverId = 99082;
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 240, 240));
  [host setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Shadow visibleShadow =
      BoxShadow(0.4, 7, -3, 48, 6, 0.1, 0.2, 0.3);
  const smoothclip::Presentation initial = PresentationValue(
      0, 0, 240, 240, 0, 0, 0, 0,
      smoothclip::ClipCurve::Circular, 0, 0, 1, visibleShadow);
  smoothclip::registerView(driverId, host, initial);

  for (const smoothclip::Shadow &targetShadow :
       {smoothclip::Shadow{}, BoxShadow(0, 0, 0, 0)}) {
    smoothclip::Presentation target = PresentationValue(
        50, 64, 110, 92, 18, 18, 18, 18,
        smoothclip::ClipCurve::Circular, 0, 0, 1, targetShadow);
    const smoothclip::TimingAnimation timing{300, 0.42, 0, 0.58, 1, 2};
    const int32_t animationId = smoothclip::animateTiming(
        driverId, {true, initial}, target, timing);
    XCTAssertGreaterThan(animationId, 0);

    CALayer *shadow = [host valueForKey:@"shadowLayer"];
    XCTAssertNotNil(shadow);
    XCTAssertEqualWithAccuracy(CGColorGetAlpha(shadow.shadowColor), 0, 1e-9);
    XCTAssertEqualWithAccuracy(shadow.shadowOpacity, 1, 1e-9);
    XCTAssertEqualWithAccuracy(shadow.shadowRadius, 24, 1e-9);
    XCTAssertEqualWithAccuracy(shadow.shadowOffset.width, 7, 1e-9);
    XCTAssertEqualWithAccuracy(shadow.shadowOffset.height, -3, 1e-9);
    XCTAssertTrue(CGRectEqualToRect(
        CGPathGetBoundingBox(shadow.shadowPath),
        CGRectMake(44, 58, 122, 104)));

    CGFloat red = 0;
    CGFloat green = 0;
    CGFloat blue = 0;
    CGFloat alpha = 1;
    XCTAssertTrue([[UIColor colorWithCGColor:shadow.shadowColor]
        getRed:&red green:&green blue:&blue alpha:&alpha]);
    XCTAssertEqualWithAccuracy(red, 0.1, 1e-6);
    XCTAssertEqualWithAccuracy(green, 0.2, 1e-6);
    XCTAssertEqualWithAccuracy(blue, 0.3, 1e-6);
    XCTAssertEqualWithAccuracy(alpha, 0, 1e-9);

    // Simulate Core Animation's automatic terminal presentation removal.
    // The model must remain invisible without waiting for the delegate.
    [shadow removeAnimationForKey:@"smoothClip.shadow"];
    XCTAssertEqualWithAccuracy(CGColorGetAlpha(shadow.shadowColor), 0, 1e-9);
    XCTAssertTrue(CGRectEqualToRect(
        CGPathGetBoundingBox(shadow.shadowPath),
        CGRectMake(44, 58, 122, 104)));

    const smoothclip::CancelResult cancelled =
        smoothclip::cancelAnimation(driverId, animationId, true);
    XCTAssertTrue(cancelled.handled);
    XCTAssertEqualWithAccuracy(CGColorGetAlpha(shadow.shadowColor), 0, 1e-9);
    smoothclip::setPresentation(driverId, initial, true);
  }

  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

- (void)testAppearingShadowStartsFromTheTargetStyleAtZeroAlpha {
  constexpr uint64_t driverId = 99083;
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 220, 220));
  [host setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation initial = PresentationValue(
      30, 40, 90, 80, 16, 16, 16, 16,
      smoothclip::ClipCurve::Circular, 0, 0, 1);
  const smoothclip::Presentation target = PresentationValue(
      0, 0, 220, 220, 0, 0, 0, 0,
      smoothclip::ClipCurve::Circular, 0, 0, 1,
      BoxShadow(0.35, 4, 5, 32, 3, 0.2, 0.3, 0.4));
  smoothclip::registerView(driverId, host, initial);

  const smoothclip::TimingAnimation timing{300, 0.42, 0, 0.58, 1, 2};
  const int32_t animationId = smoothclip::animateTiming(
      driverId, {true, initial}, target, timing);
  XCTAssertGreaterThan(animationId, 0);
  CALayer *shadow = [host valueForKey:@"shadowLayer"];
  CAAnimationGroup *shadowGroup = (CAAnimationGroup *)[shadow
      animationForKey:@"smoothClip.shadow"];
  XCTAssertNotNil(shadowGroup);
  XCTAssertEqualWithAccuracy(shadow.shadowOpacity, 1, 1e-9);
  XCTAssertEqualWithAccuracy(CGColorGetAlpha(shadow.shadowColor), 0.35, 1e-9);

  CABasicAnimation *colorAnimation = nil;
  for (CAPropertyAnimation *animation in shadowGroup.animations) {
    XCTAssertNotEqualObjects(animation.keyPath, @"shadowOpacity");
    if ([animation.keyPath isEqualToString:@"shadowColor"]) {
      colorAnimation = (CABasicAnimation *)animation;
    }
  }
  XCTAssertNotNil(colorAnimation);
  XCTAssertEqualWithAccuracy(
      CGColorGetAlpha((__bridge CGColorRef)colorAnimation.fromValue), 0, 1e-9);
  XCTAssertEqualWithAccuracy(
      CGColorGetAlpha((__bridge CGColorRef)colorAnimation.toValue), 0.35, 1e-9);

  smoothclip::cancelAnimation(driverId, animationId, false);
  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

- (void)testClipBoxShadowUsesTheRawApertureInsideTheFixedHostViewport {
  constexpr uint64_t driverId = 99080;
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  const smoothclip::Presentation visible = PresentationValue(
      -10,
      12,
      180,
      140,
      72,
      36,
      24,
      12,
      smoothclip::ClipCurve::Continuous,
      0,
      0,
      0.75,
      BoxShadow(0.25, 3, 1.5, 48, 5, 0.1, 0.2, 0.3));
  smoothclip::registerView(driverId, host, visible);

  UIView *clip = [host valueForKey:@"clipContainer"];
  CAShapeLayer *mask = (CAShapeLayer *)clip.layer.mask;
  CALayer *shadow = [host valueForKey:@"shadowLayer"];
  XCTAssertNotNil(mask);
  XCTAssertTrue(mask.path != nil);
  XCTAssertTrue(shadow.shadowPath != nil);
  XCTAssertTrue(host.clipsToBounds);
  XCTAssertTrue(CGRectEqualToRect(
      mask.bounds, CGRectMake(-10, 12, 180, 140)));
  XCTAssertEqualWithAccuracy(mask.position.x, 80, 1e-9);
  XCTAssertEqualWithAccuracy(mask.position.y, 82, 1e-9);
  // Spread expands the shadow outline beyond the clipping aperture.
  XCTAssertFalse(CGPathEqualToPath(mask.path, shadow.shadowPath));
  XCTAssertEqualWithAccuracy(shadow.shadowOpacity, 1, 1e-9);
  XCTAssertEqualWithAccuracy(shadow.shadowRadius, 24, 1e-9);
  XCTAssertEqualWithAccuracy(shadow.shadowOffset.width, 3, 1e-9);
  XCTAssertEqualWithAccuracy(shadow.shadowOffset.height, 1.5, 1e-9);

  CGPathRef originalShadowPath = CGPathCreateCopy(shadow.shadowPath);
  smoothclip::Presentation shadowOnlyUpdate = visible;
  shadowOnlyUpdate.shadow =
      BoxShadow(0.7, -2, 6, 32, 8, 0.4, 0.3, 0.2);
  smoothclip::setPresentation(driverId, shadowOnlyUpdate, true);
  XCTAssertEqualWithAccuracy(CGColorGetAlpha(shadow.shadowColor), 0.7, 1e-9);
  XCTAssertEqualWithAccuracy(shadow.shadowOffset.width, -2, 1e-9);
  XCTAssertEqualWithAccuracy(shadow.shadowOffset.height, 6, 1e-9);
  XCTAssertEqualWithAccuracy(shadow.shadowRadius, 16, 1e-9);
  XCTAssertFalse(CGPathEqualToPath(originalShadowPath, shadow.shadowPath));
  CGPathRelease(originalShadowPath);
  const smoothclip::Presentation updated =
      smoothclip::snapshotCurrent(driverId);
  XCTAssertEqualWithAccuracy(updated.shadow.spreadDistance, 8, 1e-9);

  facebook::react::LayoutMetrics oldMetrics;
  oldMetrics.frame = facebook::react::Rect{
      facebook::react::Point{0, 0}, facebook::react::Size{200, 200}};
  facebook::react::LayoutMetrics newMetrics;
  newMetrics.frame = facebook::react::Rect{
      facebook::react::Point{0, 0}, facebook::react::Size{150, 240}};
  host.frame = CGRectMake(0, 0, 150, 240);
  [host updateLayoutMetrics:newMetrics oldLayoutMetrics:oldMetrics];
  mask = (CAShapeLayer *)clip.layer.mask;
  XCTAssertTrue(CGRectEqualToRect(
      mask.bounds, CGRectMake(-10, 12, 180, 140)));
  XCTAssertFalse(CGPathEqualToPath(mask.path, shadow.shadowPath));

  smoothclip::Presentation empty = shadowOnlyUpdate;
  empty.clip.width = 0;
  smoothclip::setPresentation(driverId, empty, true);
  mask = (CAShapeLayer *)clip.layer.mask;
  XCTAssertTrue(CGPathIsEmpty(mask.path));
  XCTAssertEqualWithAccuracy(shadow.shadowOpacity, 0, 1e-9);

  smoothclip::unregisterView(driverId, host);
  smoothclip::destroyDriver(driverId);
}

- (void)testClipBoxShadowSharesTimingAndSpringAnimationGroups {
  constexpr uint64_t driverId = 99081;
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 220, 220));
  [host setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation initial = PresentationValue(
      10, 10, 60, 70, 20, 16, 12, 8,
      smoothclip::ClipCurve::Continuous, 0, 0, 1,
      BoxShadow(0, 0, 0, 0));
  const smoothclip::Presentation target = PresentationValue(
      20, 24, 160, 140, 36, 28, 20, 12,
      smoothclip::ClipCurve::Continuous, 5, -3, 0.8,
      BoxShadow(0.25, 2, 1.6, 51.2));
  const smoothclip::Presentation next = PresentationValue(
      30, 18, 140, 160, 30, 24, 18, 10,
      smoothclip::ClipCurve::Continuous, 7, -4, 0.7,
      BoxShadow(0.18, 1, 1.4, 44.8, 0, 0.2, 0.1, 0.05));
  smoothclip::registerView(driverId, host, initial);

  UIView *clip = [host valueForKey:@"clipContainer"];
  CALayer *shadow = [host valueForKey:@"shadowLayer"];
  XCTAssertNil(shadow);
  const smoothclip::TimingAnimation timing{300, 0.42, 0, 0.58, 1, 2};
  int32_t animationId = smoothclip::animateTiming(
      driverId, {true, initial}, target, timing);
  XCTAssertGreaterThan(animationId, 0);
  shadow = [host valueForKey:@"shadowLayer"];
  CAAnimationGroup *geometryGroup = (CAAnimationGroup *)[clip.layer
      animationForKey:@"smoothClip.geometry"];
  CAAnimationGroup *shadowGroup = (CAAnimationGroup *)[shadow
      animationForKey:@"smoothClip.shadow"];
  XCTAssertNotNil(geometryGroup);
  XCTAssertNotNil(shadowGroup);
  XCTAssertEqualWithAccuracy(geometryGroup.beginTime, shadowGroup.beginTime, 1e-9);
  XCTAssertEqualWithAccuracy(geometryGroup.duration, shadowGroup.duration, 1e-9);
  XCTAssertEqual(shadowGroup.animations.count, 2u);
  NSArray<NSString *> *expectedKeyPaths = @[
    @"shadowPath", @"shadowColor"
  ];
  for (NSUInteger index = 0; index < expectedKeyPaths.count; index++) {
    XCTAssertEqualObjects(
        ((CAPropertyAnimation *)shadowGroup.animations[index]).keyPath,
        expectedKeyPaths[index]);
  }
  smoothclip::CancelResult interrupted =
      smoothclip::cancelAnimation(driverId, animationId, true);
  XCTAssertTrue(interrupted.handled);
  XCTAssertEqualWithAccuracy(interrupted.presentation.shadow.alpha, 0.25, 1e-9);
  XCTAssertEqualWithAccuracy(interrupted.presentation.shadow.blurRadius, 51.2, 1e-9);

  const smoothclip::SpringAnimation spring{1, 180, 40, 0, false, 2};
  animationId = smoothclip::animateSpring(
      driverId, {true, target}, next, spring);
  XCTAssertGreaterThan(animationId, 0);
  geometryGroup = (CAAnimationGroup *)[clip.layer
      animationForKey:@"smoothClip.geometry"];
  shadowGroup = (CAAnimationGroup *)[shadow
      animationForKey:@"smoothClip.shadow"];
  XCTAssertEqualWithAccuracy(geometryGroup.beginTime, shadowGroup.beginTime, 1e-9);
  XCTAssertEqualWithAccuracy(geometryGroup.duration, shadowGroup.duration, 1e-9);
  for (CASpringAnimation *animation in shadowGroup.animations) {
    XCTAssertTrue([animation isKindOfClass:CASpringAnimation.class]);
    XCTAssertEqualWithAccuracy(animation.initialVelocity, 0, 1e-9);
    XCTAssertEqualWithAccuracy(animation.duration, shadowGroup.duration, 1e-6);
  }
  smoothclip::cancelAnimation(driverId, animationId, true);
  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

- (void)testUniformContinuousFastPathResetsToCircularUniformRendering {
  constexpr uint64_t driverId = 9071;
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  smoothclip::registerView(driverId, host, Presentation(0, 0, 50, 50, 8));
  smoothclip::setPresentation(
      driverId,
      PresentationValue(
          0, 0, 100, 80, 18, 18, 18, 18,
          smoothclip::ClipCurve::Continuous, 3, 4, 0.75),
      true);

  UIView *clip = [host valueForKey:@"clipContainer"];
  UIView *content = [host valueForKey:@"contentContainer"];
  XCTAssertNil(clip.layer.mask);
  XCTAssertEqualWithAccuracy(clip.layer.cornerRadius, 18, 1e-9);
  XCTAssertEqualObjects(clip.layer.cornerCurve, kCACornerCurveContinuous);

  // A later uniform circular presentation restores the fast path and scale 1.
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

- (void)testTimingSnapshotDoesNotCancelMaskAndScaleAnimation {
  constexpr uint64_t driverId = 9072;
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  [host setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation initial = PresentationValue(
      0, 0, 50, 50, 10, 10, 10, 10,
      smoothclip::ClipCurve::Circular, 0, 0, 1);
  const smoothclip::Presentation target = PresentationValue(
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

- (void)testCurveChangingTimingRejectsWithoutMutation {
  constexpr uint64_t driverId = 99073;
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  [host setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation initial = PresentationValue(
      5, 6, 80, 70, 16, 16, 16, 16,
      smoothclip::ClipCurve::Circular, 2, 3, 1);
  const smoothclip::Presentation target = PresentationValue(
      20, 30, 120, 100, 30, 22, 14, 6,
      smoothclip::ClipCurve::Continuous, 11, -7, 0.6);
  smoothclip::registerView(driverId, host, initial);
  const smoothclip::Presentation before =
      smoothclip::snapshotCurrent(driverId);
  int completionCount = 0;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver, int32_t, int32_t, bool) {
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


- (void)testSpringAcceptsFullyOffHostOversizedTargetAndReturnsItRaw {
  constexpr uint64_t driverId = 9907401;
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 100, 100));
  [host setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation initial =
      Presentation(10, 10, 40, 40, 8, 0, 0);
  const smoothclip::Presentation requested =
      Presentation(-280, 130, 260, 180, 200, 12, -7);
  smoothclip::registerView(driverId, host, initial);

  const smoothclip::SpringAnimation spring{1, 180, 40, 0, false, 2};
  const int32_t animationId = smoothclip::animateSpring(
      driverId, {true, initial}, requested, spring);

  XCTAssertGreaterThan(animationId, 0);
  UIView *clip = [host valueForKey:@"clipContainer"];
  CAAnimationGroup *group = (CAAnimationGroup *)[clip.layer
      animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(group);

  const smoothclip::CancelResult landed =
      smoothclip::cancelAnimation(driverId, animationId, true);
  XCTAssertTrue(landed.handled);
  XCTAssertEqualWithAccuracy(landed.presentation.clip.x, -280, 1e-9);
  XCTAssertEqualWithAccuracy(landed.presentation.clip.y, 130, 1e-9);
  XCTAssertEqualWithAccuracy(landed.presentation.clip.width, 260, 1e-9);
  XCTAssertEqualWithAccuracy(landed.presentation.clip.height, 180, 1e-9);
  XCTAssertEqualWithAccuracy(landed.presentation.clip.radius, 90, 1e-9);
  XCTAssertEqualWithAccuracy(landed.presentation.contentTranslateX, 12, 1e-9);
  XCTAssertEqualWithAccuracy(landed.presentation.contentTranslateY, -7, 1e-9);

  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

- (void)testBoundaryCrossingGroupReplacementIsAcceptedAtomically {
  constexpr uint64_t firstDriverId = 99076;
  constexpr uint64_t secondDriverId = 99077;
  UIWindow *window = TestWindow();
  SmoothClipView *first =
      DisplayableView(window, CGRectMake(0, 0, 100, 100));
  SmoothClipView *second =
      DisplayableView(window, CGRectMake(0, 0, 100, 100));
  [first setValue:@(firstDriverId) forKey:@"driverId"];
  [second setValue:@(secondDriverId) forKey:@"driverId"];
  const smoothclip::Presentation initial = PresentationValue(
      10, 10, 40, 40, 8, 8, 8, 8,
      smoothclip::ClipCurve::Circular, 0, 0, 1);
  const smoothclip::Presentation oldTarget = PresentationValue(
      20, 20, 60, 60, 12, 12, 12, 12,
      smoothclip::ClipCurve::Circular, 3, -2, 0.9);
  const smoothclip::Presentation safeReplacement = PresentationValue(
      25, 20, 50, 50, 10, 10, 10, 10,
      smoothclip::ClipCurve::Circular, 4, -3, 0.85);
  const smoothclip::Presentation crossingReplacement = PresentationValue(
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
          int32_t,
          bool finished,
          std::vector<smoothclip::DriverSnapshot>) {
        events.push_back({groupId, finished});
      });
  const smoothclip::TimingAnimation timing{500, 0.42, 0, 0.58, 1, 2};
  const int32_t oldGroupId = smoothclip::animateTimingGroup(
      99100,
      {
          GroupEntry(firstDriverId, true, initial, oldTarget),
          GroupEntry(secondDriverId, true, initial, oldTarget),
      },
      timing);
  XCTAssertGreaterThan(oldGroupId, 0);

  const int32_t replacementGroupId = smoothclip::animateTimingGroup(
      99101,
      {
          GroupEntry(firstDriverId, false, initial, safeReplacement),
          GroupEntry(secondDriverId, false, initial, crossingReplacement),
      },
      timing);

  XCTAssertGreaterThan(replacementGroupId, 0);
  XCTAssertNotEqual(replacementGroupId, oldGroupId);
  XCTAssertTrue(smoothclip::hasActiveAnimation(firstDriverId));
  XCTAssertTrue(smoothclip::hasActiveAnimation(secondDriverId));
  XCTAssertEqual(events.size(), 1u);
  XCTAssertEqual(events[0].groupId, oldGroupId);
  XCTAssertFalse(events[0].finished);
  const std::vector<smoothclip::DriverSnapshot> frozen =
      smoothclip::cancelAnimationGroup(
          replacementGroupId, smoothclip::GroupCancelBehavior::Freeze);
  XCTAssertEqual(frozen.size(), 2u);
  XCTAssertEqual(events.size(), 2u);
  XCTAssertEqual(events[1].groupId, replacementGroupId);
  XCTAssertFalse(events[1].finished);

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

  const smoothclip::Presentation initial = PresentationValue(
      0, 0, 50, 50, 12, 12, 12, 12,
      smoothclip::ClipCurve::Circular, 0, 0, 1);
  const smoothclip::Presentation target = PresentationValue(
      20, 30, 140, 100, 20, 20, 20, 20,
      smoothclip::ClipCurve::Circular, 8, -6, 0.7);
  smoothclip::registerView(firstDriverId, first, initial);
  smoothclip::registerView(secondDriverId, second, initial);

  const int32_t groupId = smoothclip::animateTimingGroup(
      7001,
      {
          GroupEntry(firstDriverId, true, initial, target),
          GroupEntry(secondDriverId, true, initial, target),
      },
      {250, 0.42, 0, 0.58, 1, 2});
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
          int32_t,
          bool finished,
          std::vector<smoothclip::DriverSnapshot> snapshots) {
        events.push_back(
            {controllerId, completedGroupId, finished, DriverIds(snapshots)});
      });
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t, int32_t, int32_t, bool) {
        singleCompletionCount += 1;
      });

  const smoothclip::TimingAnimation timing{500, 0.42, 0, 0.58, 1, 2};
  const int32_t oldGroupId = smoothclip::animateTimingGroup(
      7002,
      {
          GroupEntry(firstDriverId, true, initial, firstTarget),
          GroupEntry(secondDriverId, true, initial, firstTarget),
      },
      timing);
  XCTAssertGreaterThan(oldGroupId, 0);

  // The missing driver has no authoritative from value, so the entire
  // replacement rejects before it can freeze either old participant.
  const int32_t rejected = smoothclip::animateTimingGroup(
      7003,
      {
          GroupEntry(firstDriverId, false, initial, replacementTarget),
          GroupEntry(missingDriverId, false, initial, replacementTarget),
      },
      timing);
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
      timing);
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
  const smoothclip::Presentation batchValue = PresentationValue(
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
          int32_t,
          bool finished,
          std::vector<smoothclip::DriverSnapshot> snapshots) {
        groupCompletionCount += 1;
        groupFinished = finished;
        completedDrivers = DriverIds(snapshots);
      });
  const int32_t groupId = smoothclip::animateTimingGroup(
      7005,
      {
          GroupEntry(firstDriverId, true, initial, target),
          GroupEntry(secondDriverId, true, initial, target),
      },
      {500, 0.42, 0, 0.58, 1, 2});
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
  const smoothclip::Presentation finishTarget = PresentationValue(
      30, 20, 140, 110, 18, 18, 18, 18,
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
          int32_t,
          bool finished,
          std::vector<smoothclip::DriverSnapshot> snapshots) {
        events.push_back({groupId, finished, DriverIds(snapshots)});
      });
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t, int32_t, int32_t, bool) {
        singleCompletionCount += 1;
      });

  const int32_t completedGroupId = smoothclip::animateTimingGroup(
      7006,
      {
          GroupEntry(firstDriverId, true, initial, target),
          GroupEntry(secondDriverId, true, initial, target),
      },
      {500, 0.42, 0, 0.58, 1, 2});
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
      {500, 0.42, 0, 0.58, 1, 2});
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

- (void)testHostLossFinishesStandaloneAnimationAtTarget {
  constexpr uint64_t driverId = 9082;
  UIWindow *window = TestWindow();
  SmoothClipView *view =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  const smoothclip::Presentation initial =
      Presentation(-20, 10, 60, 70, 12);
  const smoothclip::Presentation target =
      Presentation(240, -30, 160, 140, 24);
  int completionCount = 0;
  BOOL completedFinished = NO;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver, int32_t, int32_t, bool finished) {
        if (completedDriver != driverId) return;
        completionCount += 1;
        completedFinished = finished;
      });
  smoothclip::registerView(driverId, view, initial);
  XCTAssertGreaterThan(
      smoothclip::animateTiming(
          driverId,
          {true, initial},
          target,
          {500, 0.42, 0, 0.58, 1, 2}),
      0);

  smoothclip::unregisterView(driverId, view);

  XCTAssertEqual(completionCount, 1);
  XCTAssertTrue(completedFinished);
  const smoothclip::Presentation snapshot =
      smoothclip::snapshotCurrent(driverId);
  XCTAssertEqualWithAccuracy(snapshot.clip.x, target.clip.x, 1e-9);
  XCTAssertEqualWithAccuracy(snapshot.clip.y, target.clip.y, 1e-9);
  XCTAssertEqualWithAccuracy(snapshot.clip.width, target.clip.width, 1e-9);
  smoothclip::clearCompletionCallback((__bridge const void *)self);
  smoothclip::destroyDriver(driverId);
}

- (void)testBackgroundFreezesGroupWithOrderedSnapshots {
  constexpr uint64_t firstDriverId = 9083;
  constexpr uint64_t secondDriverId = 9084;
  UIWindow *window = TestWindow();
  SmoothClipView *first =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  SmoothClipView *second =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 12);
  const smoothclip::Presentation firstTarget =
      Presentation(-80, 20, 120, 100, 18);
  const smoothclip::Presentation secondTarget =
      Presentation(220, -40, 160, 140, 24);
  smoothclip::registerView(firstDriverId, first, initial);
  smoothclip::registerView(secondDriverId, second, initial);
  std::vector<smoothclip::DriverSnapshot> completionSnapshots;
  BOOL completedFinished = NO;
  smoothclip::setGroupCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t,
          int32_t,
          int32_t,
          bool finished,
          std::vector<smoothclip::DriverSnapshot> snapshots) {
        completedFinished = finished;
        completionSnapshots = std::move(snapshots);
      });
  XCTAssertGreaterThan(
      smoothclip::animateTimingGroup(
          7008,
          {
              GroupEntry(firstDriverId, true, initial, firstTarget),
              GroupEntry(secondDriverId, true, initial, secondTarget),
          },
          {500, 0.42, 0, 0.58, 1, 2}),
      0);

  smoothclip::applicationWillResignActive();

  XCTAssertFalse(completedFinished);
  XCTAssertEqual(completionSnapshots.size(), 2u);
  XCTAssertEqual(completionSnapshots[0].driverId, firstDriverId);
  XCTAssertEqual(completionSnapshots[1].driverId, secondDriverId);
  XCTAssertTrue(
      std::isfinite(completionSnapshots[0].presentation.clip.x));
  XCTAssertTrue(
      std::isfinite(completionSnapshots[1].presentation.clip.x));
  smoothclip::applicationDidBecomeActive();
  smoothclip::clearGroupCompletionCallback((__bridge const void *)self);
  smoothclip::unregisterView(firstDriverId, first);
  smoothclip::unregisterView(secondDriverId, second);
  smoothclip::destroyDriver(firstDriverId);
  smoothclip::destroyDriver(secondDriverId);
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

// An animateTo issued before any host view registers must remain pending
// instead of instant-completing at the target — the pre-0.2.1
// behavior made a host that mounted one frame later jump straight to the
// target. A valid interactive start is authoritative enough to create the
// missing driver entry; no earlier hook seed is required.
- (void)testAnimateWithoutViewsWaitsUntilFirstRegistration {
  constexpr uint64_t driverId = 9004;
  int completionCount = 0;
  int32_t completedAnimation = 0;
  BOOL completedFinished = YES;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver,
          int32_t animationId,
          int32_t,
          bool finished) {
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

  // First displayable registration starts the pending run; the animation stays
  // active and still has not completed.
  smoothclip::registerView(driverId, view, initial);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  XCTAssertEqual(completionCount, 0);

  // Once motion has started, host loss applies the target and completes the
  // run successfully instead of preserving an offscreen native clock.
  smoothclip::unregisterView(driverId, view);
  XCTAssertEqual(completionCount, 1);
  XCTAssertEqual(completedAnimation, animationId);
  XCTAssertTrue(completedFinished);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));
  XCTAssertEqualWithAccuracy(
      smoothclip::snapshotCurrent(driverId).clip.width,
      target.clip.width,
      1e-9);
  smoothclip::destroyDriver(driverId);
  smoothclip::clearCompletionCallback((__bridge const void *)self);
}

// Both entry points share the pre-registration creation rule.
- (void)testSpringCreatesAPreRegistrationRun {
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
}

// A pending animation never rendered, so freezing it (cancel without target /
// beginInteraction) must return its start — state.latest already holds the
// target, and freezing there would jump the clip.
- (void)testCancelingAPendingAnimationFreezesAtItsStart {
  constexpr uint64_t driverId = 9014;
  int completionCount = 0;
  BOOL completedFinished = YES;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver,
          int32_t animationId,
          int32_t,
          bool finished) {
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

// The first registration starts a fresh native clock: the installed
// transition must run its full duration rather than counting pre-mount time.
- (void)testRegisterStartsPendingAnimationFromItsStartWithFullDuration {
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

// Replacing a pending animation (open then close before the host mounted)
// must cancel the first run unfinished and start the second from the first
// run's start — not from state.latest, which holds the first target.
- (void)testReplacingAPendingAnimationStartsFromThePendingStart {
  constexpr uint64_t driverId = 9016;
  int completionCount = 0;
  int32_t lastCompleted = 0;
  BOOL lastFinished = YES;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver,
          int32_t animationId,
          int32_t,
          bool finished) {
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

  // The replacement retained the first run's start; freezing proves it.
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

// A run whose host never mounts survives until the driver is destroyed
// and then delivers its single unfinished completion.
- (void)testDestroyDriverCancelsAPendingAnimation {
  constexpr uint64_t driverId = 9017;
  int completionCount = 0;
  BOOL completedFinished = YES;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver,
          int32_t animationId,
          int32_t,
          bool finished) {
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

- (void)testPresentationRoundTripsExactly {
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
// cleanup; see src/__tests__/controllers.native.test.ts. Deleting either half
// reopens a pending run whose completion never arrives.
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

- (void)testSpringUsesNormalizedVelocityAndOneSharedEnergyDuration {
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
    // One energy-based scalar solve determines the transaction duration; every
    // property animation receives that same duration.
    XCTAssertEqualWithAccuracy(animation.duration, group.duration, 1e-6);
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
// model values — the target. The run therefore must stay pending for a
// registered-but-detached view and start inside the window-attach commit
// with its full duration (the northernLights_new map-overlay bug).
- (void)testPendingRunForDetachedViewStartsAtWindowAttach {
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
  // Laid out but not in a window: registration must keep the run pending and
  // must not install any CA animation.
  smoothclip::registerView(driverId, view, initial);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  UIView *container = [view valueForKey:@"clipContainer"];
  XCTAssertNil([container.layer animationForKey:@"smoothClip.geometry"]);

  // Window attach (didMoveToWindow → displayability update) starts the
  // run with the full duration, inside the attach commit.
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

// Reduce Motion is honored before readiness: an animateTo with no views and
// reduceMotion=always instant-completes at the target with finished:true.
// This is deliberate platform behavior.
- (void)testReduceMotionInstantCompletesBeforeHostReadiness {
  constexpr uint64_t driverId = 9019;
  int completionCount = 0;
  int32_t completedTag = 0;
  BOOL completedFinished = NO;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver,
          int32_t animationId,
          int32_t completionTag,
          bool finished) {
        if (completedDriver != driverId) return;
        completionCount += 1;
        completedTag = completionTag;
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
      driverId, {true, initial}, target, timing, 73);
  XCTAssertGreaterThan(animationId, 0);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));
  XCTAssertEqual(completionCount, 1);
  XCTAssertEqual(completedTag, 73);
  XCTAssertTrue(completedFinished);
  const smoothclip::Presentation current =
      smoothclip::beginInteraction(driverId);
  XCTAssertEqual(current.clip.width, target.clip.width);
  smoothclip::clearCompletionCallback((__bridge const void *)self);
  smoothclip::destroyDriver(driverId);
}

// The hook's take-ownership seed replays a SharedValue an earlier animateTo
// already advanced to its target. A pending run is strictly newer intent, so
// the seed must not cancel it (that would seed the target and turn the
// pending animation into a static jump).
- (void)testTakeOwnershipSeedDoesNotCancelAPendingRun {
  constexpr uint64_t driverId = 9020;
  int completionCount = 0;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver,
          int32_t animationId,
          int32_t,
          bool finished) {
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

  // The run still starts from its own start on the first displayable host.
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

// animation.from is fresher intent than a pending run. Its fused native write
// opts into one unfinished cancellation, establishes the new native start,
// and the replacement then freezes from that exact value.
- (void)testExplicitFromReplacesAPendingRunOnce {
  constexpr uint64_t driverId = 9027;
  int completionCount = 0;
  int32_t lastCompleted = 0;
  BOOL lastFinished = YES;
  smoothclip::setCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedDriver,
          int32_t animationId,
          int32_t,
          bool finished) {
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



// A host attached before its first positive layout cannot render yet. Time
// spent waiting for that layout must not consume the animation duration.
- (void)testZeroSizedFirstLayoutKeepsTheRunPendingUntilPositiveLayout {
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
  // The pending run burns no time before it can be seen, so the whole 250 ms
  // is still ahead of it.
  XCTAssertEqualWithAccuracy(group.duration, 0.25, 1e-3);

  smoothclip::cancelAnimation(driverId, 0, false);
  smoothclip::unregisterView(driverId, host);
  smoothclip::destroyDriver(driverId);
}

// A pending animation has no visible intermediate presentation. Cancelling it
// to target must apply that target to the host and registry together.
- (void)testCancelToTargetAppliesTheTargetWhenTheAnimationWasPending {
  constexpr uint64_t driverId = 9033;
  // Laid out but NOT in a window: cannot display, so the animation waits
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


// Cancel-to-target of a pending run applies the target to the hosts but must
// not enter the 'inherit' velocity history: a jump to the target is not
// interactive motion, and Android's cancel fan-out records nothing. Unfixed,
// the animate→cancel sample pair (16 ms apart here) reads as real motion and
// launches the next inherited spring with a phantom velocity.
- (void)testPendingCancelToTargetDoesNotEnterTheInheritHistory {
  constexpr uint64_t driverId = 9041;
  UIWindow *window = TestWindow();
  // Laid out but detached: velocity samples record (hasLayout) while any
  // animation can only remain pending (no window).
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
  // target is deliberately NOT the cancelled run's target so a phantom
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
      [&](uint64_t completedDriver, int32_t, int32_t, bool finished) {
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

@end
