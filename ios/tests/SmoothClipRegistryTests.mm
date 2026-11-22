#import <XCTest/XCTest.h>

#import "SmoothClipBackdropView.h"
#import "SmoothClipFlight.h"
#import "SmoothClipFlightTargetView.h"
#import "SmoothClipView.h"
#import "SmoothClipViewRegistry.h"

#import <QuartzCore/QuartzCore.h>
#import <React/RCTMountingTransactionObserving.h>
#import <react/renderer/components/SmoothClipViewSpec/Props.h>
#import <react/renderer/core/LayoutMetrics.h>
#import <react/renderer/mounting/MountingTransaction.h>
#import <react/renderer/telemetry/SurfaceTelemetry.h>

#include "SmoothClipAnimationCurve.h"
#include "SmoothClipFlightGeometry.h"

#include <cmath>
#include <unistd.h>

@interface SmoothClipView (SmoothClipRegistryTests)
- (void)smoothClipApplyPresentation:(smoothclip::Presentation)presentation;
- (BOOL)smoothClipAnimateTiming:(smoothclip::Presentation)presentation
                     animation:(smoothclip::TimingAnimation)animation
                   animationId:(int32_t)animationId sharedBeginTime:(CFTimeInterval)beginTime;
- (BOOL)smoothClipAnimateSpring:(smoothclip::Presentation)presentation
                     animation:(smoothclip::SpringAnimation)animation
                   animationId:(int32_t)animationId;
- (BOOL)smoothClipAnimateSpring:(smoothclip::Presentation)presentation
                     animation:(smoothclip::SpringAnimation)animation
                   animationId:(int32_t)animationId
               sharedBeginTime:(CFTimeInterval)beginTime;
- (BOOL)smoothClipPauseSpringAnimation:(int32_t)animationId atMediaTime:(CFTimeInterval)mediaTime;
- (BOOL)smoothClipResumeSpringAnimation:(int32_t)animationId atMediaTime:(CFTimeInterval)mediaTime
                            catchUpBy:(CFTimeInterval)catchUp;

- (smoothclip::Presentation)smoothClipCurrentPresentation;
- (void)smoothClipAnimationDidStopWithDriverId:(uint64_t)driverId
                                    animationId:(int32_t)animationId
                                       finished:(BOOL)finished;
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
              shadowSpreadDistance:(double)shadowSpreadDistance
                          rotation:(double)rotation
                           opacity:(double)opacity;
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
              shadowSpreadDistance:0 rotation:0 opacity:1];
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
              shadowSpreadDistance:5 rotation:0 opacity:1];
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
              shadowSpreadDistance:5 rotation:0 opacity:1];
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
              shadowSpreadDistance:5 rotation:0 opacity:1];
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

- (void)testUniformContinuousGroupAnimatesCornerRadiusWithoutMask {
  constexpr uint64_t driverId = 99075;
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  [host setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation initial = PresentationValue(
      0, 0, 50, 50, 12, 12, 12, 12,
      smoothclip::ClipCurve::Continuous, 0, 0, 1);
  const smoothclip::Presentation target = PresentationValue(
      20, 30, 140, 100, 20, 20, 20, 20,
      smoothclip::ClipCurve::Continuous, 8, -6, 0.7);
  smoothclip::registerView(driverId, host, initial);

  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};
  const int32_t groupId = smoothclip::animateTimingGroup(
      7090, {GroupEntry(driverId, true, initial, target)}, timing);
  XCTAssertGreaterThan(groupId, 0);

  CALayer *layer = ((UIView *)[host valueForKey:@"clipContainer"]).layer;
  XCTAssertNil(layer.mask);
  XCTAssertEqualObjects(layer.cornerCurve, kCACornerCurveContinuous);
  XCTAssertEqualWithAccuracy(layer.cornerRadius, 20, 1e-9);
  CAAnimationGroup *geometry = (CAAnimationGroup *)[layer
      animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(geometry);
  BOOL animatesCornerRadius = NO;
  for (CAAnimation *animation in geometry.animations) {
    if ([animation isKindOfClass:[CAPropertyAnimation class]] &&
        [((CAPropertyAnimation *)animation).keyPath
            isEqualToString:@"cornerRadius"]) {
      animatesCornerRadius = YES;
    }
  }
  XCTAssertTrue(animatesCornerRadius);

  // An interruption snapshot keeps the curve, so the next run stays eligible.
  const smoothclip::Presentation frozen = smoothclip::beginInteraction(driverId);
  XCTAssertEqual(frozen.clip.curve, smoothclip::ClipCurve::Continuous);
  XCTAssertGreaterThan(
      smoothclip::animateTimingGroup(
          7091, {GroupEntry(driverId, false, initial, target)}, timing),
      0);

  // A curve change still needs path interpolation and rejects.
  const smoothclip::Presentation circularTarget = PresentationValue(
      20, 30, 140, 100, 20, 20, 20, 20,
      smoothclip::ClipCurve::Circular, 8, -6, 0.7);
  XCTAssertEqual(
      smoothclip::animateTimingGroup(
          7092, {GroupEntry(driverId, true, initial, circularTarget)}, timing),
      0);

  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
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

- (void)testTemporaryInactivityKeepsRunningGroupActive {
  constexpr uint64_t driverId = 9085;
  UIWindow *window = TestWindow();
  SmoothClipView *view =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 12);
  const smoothclip::Presentation target =
      Presentation(200, 20, 120, 100, 18);
  int completionCount = 0;
  BOOL completedFinished = YES;
  smoothclip::setGroupCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t,
          int32_t,
          int32_t,
          bool finished,
          std::vector<smoothclip::DriverSnapshot>) {
        completionCount += 1;
        completedFinished = finished;
      });
  smoothclip::registerView(driverId, view, initial);
  const int32_t groupId = smoothclip::animateTimingGroup(
      7009,
      {GroupEntry(driverId, true, initial, target)},
      {5000, 0.42, 0, 0.58, 1, 2});
  XCTAssertGreaterThan(groupId, 0);
  UIView *container = [view valueForKey:@"clipContainer"];
  CAAnimation *animation =
      [container.layer animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(animation);
  const CFTimeInterval beginTime = animation.beginTime;

  smoothclip::applicationWillResignActive();
  XCTAssertEqual(completionCount, 0);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));

  smoothclip::applicationDidBecomeActive();
  XCTAssertEqual(completionCount, 0);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  animation = [container.layer animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(animation);
  XCTAssertEqualWithAccuracy(animation.beginTime, beginTime, 1e-9);

  smoothclip::cancelAnimationGroup(
      groupId, smoothclip::GroupCancelBehavior::Freeze);
  XCTAssertEqual(completionCount, 1);
  XCTAssertFalse(completedFinished);
  smoothclip::clearGroupCompletionCallback((__bridge const void *)self);
  smoothclip::unregisterView(driverId, view);
  smoothclip::destroyDriver(driverId);
}

- (void)testSpringInactivityPausesAndResumesWithClampedCatchUp {
  constexpr uint64_t driverId = 9093;
  UIWindow *window = TestWindow();
  SmoothClipView *view =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 12);
  const smoothclip::Presentation target =
      Presentation(180, 30, 140, 110, 20);
  const smoothclip::SpringAnimation spring{4, 900, 120, 0, false, 2};
  int completionCount = 0;
  smoothclip::setGroupCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t,
          int32_t,
          int32_t,
          bool,
          std::vector<smoothclip::DriverSnapshot>) {
        completionCount += 1;
      });
  smoothclip::registerView(driverId, view, initial);
  const int32_t groupId = smoothclip::animateSpringGroup(
      7016,
      {GroupEntry(driverId, true, initial, target)},
      spring);
  XCTAssertGreaterThan(groupId, 0);

  UIView *container = [view valueForKey:@"clipContainer"];
  smoothclip::applicationWillResignActive();
  CAAnimation *paused =
      [container.layer animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(paused);
  XCTAssertEqualWithAccuracy(paused.speed, 0, 1e-9);
  const CFTimeInterval pausedOffset = paused.timeOffset;
  const CFTimeInterval duration = paused.duration;

  // A gap longer than Reanimated's 64 ms clamp must not be consumed in full.
  usleep(100000);
  smoothclip::applicationDidBecomeActive();

  CAAnimation *resumed =
      [container.layer animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(resumed);
  XCTAssertEqualWithAccuracy(resumed.speed, 1, 1e-9);
  const CFTimeInterval localNow =
      [container.layer convertTime:CACurrentMediaTime() fromLayer:nil];
  const CFTimeInterval resumedElapsed = localNow - resumed.beginTime;
  const CFTimeInterval expectedElapsed =
      MIN(duration, pausedOffset + 0.064);
  XCTAssertEqualWithAccuracy(resumedElapsed, expectedElapsed, 0.02);
  XCTAssertEqual(completionCount, 0);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));

  smoothclip::cancelAnimationGroup(
      groupId, smoothclip::GroupCancelBehavior::Freeze);
  XCTAssertEqual(completionCount, 1);
  smoothclip::clearGroupCompletionCallback((__bridge const void *)self);
  smoothclip::unregisterView(driverId, view);
  smoothclip::destroyDriver(driverId);
}

- (void)testSetFrameDuringInactiveSpringFreezesAndCompletesOnce {
  constexpr uint64_t driverId = 9094;
  constexpr uint64_t controllerId = 7017;
  UIWindow *window = TestWindow();
  SmoothClipView *view =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 12);
  const smoothclip::Presentation target =
      Presentation(180, 30, 140, 110, 20);
  const smoothclip::Presentation interactive =
      Presentation(35, 12, 80, 70, 16);
  const smoothclip::SpringAnimation spring{4, 900, 120, 0, false, 2};
  int completionCount = 0;
  BOOL completedFinished = YES;
  int32_t completedGroupId = 0;
  smoothclip::setGroupCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t completedController,
          int32_t groupId,
          int32_t,
          bool finished,
          std::vector<smoothclip::DriverSnapshot>) {
        if (completedController != controllerId) return;
        completionCount += 1;
        completedFinished = finished;
        completedGroupId = groupId;
      });
  smoothclip::registerView(driverId, view, initial);
  const int32_t groupId = smoothclip::animateSpringGroup(
      controllerId,
      {GroupEntry(driverId, true, initial, target)},
      spring);
  XCTAssertGreaterThan(groupId, 0);

  smoothclip::applicationWillResignActive();
  XCTAssertTrue(smoothclip::setPresentationBatch({
      {driverId, interactive},
  }));

  XCTAssertEqual(completionCount, 1);
  XCTAssertFalse(completedFinished);
  XCTAssertEqual(completedGroupId, groupId);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));
  XCTAssertEqualWithAccuracy(
      smoothclip::snapshotCurrent(driverId).clip.x,
      interactive.clip.x,
      1e-9);

  smoothclip::applicationDidBecomeActive();
  XCTAssertEqual(completionCount, 1);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));
  XCTAssertEqualWithAccuracy(
      smoothclip::snapshotCurrent(driverId).clip.x,
      interactive.clip.x,
      1e-9);
  smoothclip::clearGroupCompletionCallback((__bridge const void *)self);
  smoothclip::unregisterView(driverId, view);
  smoothclip::destroyDriver(driverId);
}

- (void)testDisplayabilityCallbackDuringInactivityDoesNotBecomeHostLoss {
  constexpr uint64_t driverId = 9089;
  UIWindow *window = TestWindow();
  SmoothClipView *view =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 12);
  const smoothclip::Presentation target =
      Presentation(200, 20, 120, 100, 18);
  int completionCount = 0;
  smoothclip::setGroupCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t,
          int32_t,
          int32_t,
          bool,
          std::vector<smoothclip::DriverSnapshot>) {
        completionCount += 1;
      });
  smoothclip::registerView(driverId, view, initial);
  const int32_t groupId = smoothclip::animateTimingGroup(
      7013,
      {GroupEntry(driverId, true, initial, target)},
      {5000, 0.42, 0, 0.58, 1, 2});
  XCTAssertGreaterThan(groupId, 0);

  smoothclip::applicationWillResignActive();
  smoothclip::viewDisplayabilityChanged(driverId, view);

  XCTAssertEqual(completionCount, 0);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));

  smoothclip::applicationDidBecomeActive();
  smoothclip::cancelAnimationGroup(
      groupId, smoothclip::GroupCancelBehavior::Freeze);
  smoothclip::clearGroupCompletionCallback((__bridge const void *)self);
  smoothclip::unregisterView(driverId, view);
  smoothclip::destroyDriver(driverId);
}

- (void)testInactiveDelegateInterruptionFinishesAtTargetOnReactivation {
  constexpr uint64_t driverId = 9086;
  UIWindow *window = TestWindow();
  SmoothClipView *view =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 12);
  const smoothclip::Presentation target =
      Presentation(180, 30, 140, 110, 20);
  int completionCount = 0;
  BOOL completedFinished = NO;
  std::vector<smoothclip::DriverSnapshot> completionSnapshots;
  smoothclip::setGroupCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t,
          int32_t,
          int32_t,
          bool finished,
          std::vector<smoothclip::DriverSnapshot> snapshots) {
        completionCount += 1;
        completedFinished = finished;
        completionSnapshots = std::move(snapshots);
      });
  smoothclip::registerView(driverId, view, initial);
  const int32_t groupId = smoothclip::animateTimingGroup(
      7010,
      {GroupEntry(driverId, true, initial, target)},
      {5000, 0.42, 0, 0.58, 1, 2});
  XCTAssertGreaterThan(groupId, 0);

  smoothclip::applicationWillResignActive();
  [view smoothClipAnimationDidStopWithDriverId:driverId
                                   animationId:groupId
                                      finished:NO];
  XCTAssertEqual(completionCount, 0);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  const smoothclip::Presentation inactivePresentation =
      [view smoothClipCurrentPresentation];
  XCTAssertEqualWithAccuracy(
      inactivePresentation.clip.x, target.clip.x, 1e-9);

  smoothclip::applicationDidBecomeActive();
  XCTAssertEqual(completionCount, 1);
  XCTAssertTrue(completedFinished);
  XCTAssertEqual(completionSnapshots.size(), 1u);
  XCTAssertEqualWithAccuracy(
      completionSnapshots[0].presentation.clip.x, target.clip.x, 1e-9);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));

  smoothclip::clearGroupCompletionCallback((__bridge const void *)self);
  smoothclip::unregisterView(driverId, view);
  smoothclip::destroyDriver(driverId);
}

- (void)testRemovedAnimationWithoutDelegateCallbackFinishesOnReactivation {
  constexpr uint64_t driverId = 9092;
  UIWindow *window = TestWindow();
  SmoothClipView *view =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 12);
  const smoothclip::Presentation target =
      Presentation(180, 30, 140, 110, 20);
  int completionCount = 0;
  BOOL completedFinished = NO;
  smoothclip::setGroupCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t,
          int32_t,
          int32_t,
          bool finished,
          std::vector<smoothclip::DriverSnapshot>) {
        completionCount += 1;
        completedFinished = finished;
      });
  smoothclip::registerView(driverId, view, initial);
  const int32_t groupId = smoothclip::animateTimingGroup(
      7015,
      {GroupEntry(driverId, true, initial, target)},
      {5000, 0.42, 0, 0.58, 1, 2});
  XCTAssertGreaterThan(groupId, 0);

  smoothclip::applicationWillResignActive();
  UIView *container = [view valueForKey:@"clipContainer"];
  [container.layer removeAnimationForKey:@"smoothClip.geometry"];
  smoothclip::applicationDidBecomeActive();

  XCTAssertEqual(completionCount, 1);
  XCTAssertTrue(completedFinished);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));

  [view smoothClipAnimationDidStopWithDriverId:driverId
                                   animationId:groupId
                                      finished:NO];
  XCTAssertEqual(completionCount, 1);

  smoothclip::clearGroupCompletionCallback((__bridge const void *)self);
  smoothclip::unregisterView(driverId, view);
  smoothclip::destroyDriver(driverId);
}

- (void)testGroupRequestedWhileInactiveWaitsForActive {
  constexpr uint64_t driverId = 9090;
  UIWindow *window = TestWindow();
  SmoothClipView *view =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  const smoothclip::Presentation initial =
      Presentation(0, 0, 40, 40, 12);
  const smoothclip::Presentation target =
      Presentation(140, 15, 100, 90, 16);
  int completionCount = 0;
  smoothclip::registerView(driverId, view, initial);
  smoothclip::setGroupCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t,
          int32_t,
          int32_t,
          bool,
          std::vector<smoothclip::DriverSnapshot>) {
        completionCount += 1;
      });
  smoothclip::applicationWillResignActive();

  const int32_t groupId = smoothclip::animateTimingGroup(
      7014,
      {GroupEntry(driverId, true, initial, target)},
      {5000, 0.42, 0, 0.58, 1, 2});
  XCTAssertGreaterThan(groupId, 0);
  XCTAssertEqual(completionCount, 0);
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  UIView *container = [view valueForKey:@"clipContainer"];
  XCTAssertNil([container.layer animationForKey:@"smoothClip.geometry"]);

  smoothclip::applicationDidBecomeActive();
  XCTAssertEqual(completionCount, 0);
  XCTAssertNotNil([container.layer animationForKey:@"smoothClip.geometry"]);

  smoothclip::cancelAnimationGroup(
      groupId, smoothclip::GroupCancelBehavior::Freeze);
  smoothclip::clearGroupCompletionCallback((__bridge const void *)self);
  smoothclip::unregisterView(driverId, view);
  smoothclip::destroyDriver(driverId);
}

// A host that can display is not on screen until its commit: a run started on
// the flag before then would join that commit partway through its curve.
- (void)testSnapshotIsReadyOnlyOnceTheHostIsCommitted {
  constexpr uint64_t driverId = 9907402;
  UIWindow *window = TestWindow();
  window.rootViewController = [UIViewController new];
  [window makeKeyAndVisible];
  [CATransaction flush];
  SmoothClipView *view = DisplayableView(window, CGRectMake(0, 0, 120, 120));
  const smoothclip::Presentation frame = Presentation(0, 0, 40, 40, 20);
  smoothclip::setPresentation(driverId, frame, true);
  smoothclip::registerView(driverId, view, frame);

  XCTAssertFalse(smoothclip::snapshotGroup({driverId})[0].ready);
  [CATransaction flush];
  XCTAssertTrue(smoothclip::snapshotGroup({driverId})[0].ready);

  smoothclip::unregisterView(driverId, view);
  XCTAssertFalse(smoothclip::snapshotGroup({driverId})[0].ready);
  smoothclip::destroyDriver(driverId);
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

// A completion delivered while inactive stays pending until foreground
// reconciliation, matching Reanimated's paused callback delivery.
- (void)testInactiveCompletionWaitsForReactivation {
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
  const int32_t animationId =
      smoothclip::animateTiming(driverId, {true, initial}, target, timing);
  XCTAssertGreaterThan(animationId, 0);
  smoothclip::applicationWillResignActive();
  [host smoothClipAnimationDidStopWithDriverId:driverId
                                    animationId:animationId
                                       finished:YES];
  XCTAssertEqual(completionCount, 0);

  smoothclip::applicationDidBecomeActive();
  XCTAssertEqual(completionCount, 1);
  XCTAssertTrue(completedFinished);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));

  smoothclip::unregisterView(driverId, host);
  smoothclip::clearCompletionCallback((__bridge const void *)self);
  smoothclip::destroyDriver(driverId);
}


- (void)testAppearanceRotatesTheApertureAndShadowInsideTheFixedHost {
  UIWindow *window = TestWindow();
  SmoothClipView *host = DisplayableView(window, CGRectMake(0, 0, 100, 100));
  auto frame = Presentation(20, 40, 60, 20, 0);
  frame.rotation = M_PI_2;
  frame.opacity = 0.5;
  frame.shadow = BoxShadow(0.5, 0, 4, 8);
  [host smoothClipApplyPresentation:frame];
  UIView *group = [host valueForKey:@"presentationContainer"];
  UIView *clip = [host valueForKey:@"clipContainer"];
  CALayer *shadow = [host valueForKey:@"shadowLayer"];
  XCTAssertTrue(host.clipsToBounds);
  XCTAssertFalse(group.clipsToBounds);
  XCTAssertEqual(clip.superview, group);
  XCTAssertEqual(shadow.superlayer, group.layer);
  XCTAssertEqualWithAccuracy(group.layer.opacity, 0.5, 1e-6);
  XCTAssertTrue([host pointInside:CGPointMake(50, 25) withEvent:nil]);
  XCTAssertFalse([host pointInside:CGPointMake(25, 50) withEvent:nil]);
  CGPoint rotated = [group.layer convertPoint:CGPointMake(80, 50) toLayer:host.layer];
  XCTAssertEqualWithAccuracy(rotated.x, 50, 1e-5);
  XCTAssertEqualWithAccuracy(rotated.y, 80, 1e-5);
  CGPathRef originalShadowPath = CGPathRetain(shadow.shadowPath);
  frame.rotation = 5 * M_PI;
  frame.opacity = 0;
  [host smoothClipApplyPresentation:frame];
  XCTAssertTrue(originalShadowPath == shadow.shadowPath);
  CGPathRelease(originalShadowPath);
  XCTAssertFalse([host pointInside:CGPointMake(50, 50) withEvent:nil]);
  XCTAssertTrue(clip.accessibilityElementsHidden);
  const auto snapshot = [host smoothClipCurrentPresentation];
  XCTAssertEqualWithAccuracy(snapshot.rotation, 5 * M_PI, 1e-10);
  XCTAssertEqual(snapshot.opacity, 0);
}

- (void)testAppearanceAnimationSharesPivotClockAndSurvivesSpringPause {
  UIWindow *window = TestWindow();
  SmoothClipView *host = DisplayableView(window, CGRectMake(0, 0, 200, 200));
  auto from = Presentation(10, 20, 80, 40, 8);
  [host smoothClipApplyPresentation:from];
  auto to = Presentation(50, 60, 120, 80, 16);
  to.rotation = 4 * M_PI;
  to.opacity = 0;
  smoothclip::SpringAnimation spring{};
  spring.mass = 1; spring.stiffness = 100; spring.damping = 20;
  XCTAssertTrue([host smoothClipAnimateSpring:to animation:spring animationId:12345]);
  UIView *group = [host valueForKey:@"presentationContainer"];
  CAAnimationGroup *animation = (CAAnimationGroup *)[group.layer animationForKey:@"smoothClip.appearance"];
  XCTAssertNotNil(animation);
  XCTAssertEqual(animation.animations.count, 6u);
  XCTAssertTrue([host smoothClipPauseSpringAnimation:12345 atMediaTime:CACurrentMediaTime()]);
  XCTAssertEqual([group.layer animationForKey:@"smoothClip.appearance"].speed, 0);
  XCTAssertTrue([host smoothClipResumeSpringAnimation:12345 atMediaTime:CACurrentMediaTime() catchUpBy:0.016]);
  XCTAssertEqual([group.layer animationForKey:@"smoothClip.appearance"].speed, 1);
  [host smoothClipApplyPresentation:to];
  XCTAssertNil([group.layer animationForKey:@"smoothClip.appearance"]);
  XCTAssertEqualWithAccuracy([host smoothClipCurrentPresentation].rotation, 4 * M_PI, 1e-10);
}


- (void)testVisibleFullTurnRotationCanBeInterruptedWithoutWrapping {
  UIWindow *window = TestWindow();
  window.rootViewController = [UIViewController new];
  [window makeKeyAndVisible];
  SmoothClipView *host = DisplayableView(window, CGRectMake(0, 0, 200, 200));
  auto from = Presentation(20, 40, 100, 60, 8);
  [host smoothClipApplyPresentation:from];
  [CATransaction flush];
  auto target = from;
  UIView *content = [host valueForKey:@"contentContainer"];
  UIView *child = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 200, 200)];
  [content addSubview:child];
  target.rotation = 8 * M_PI;
  target.opacity = 0;
  // A long linear run begun well in the past: the read below lands between
  // one turn (t = 5 s) and the end (t = 20 s) however long the flush and the
  // run loop take on a loaded machine. With a 2 s run begun 0.6 s ago the
  // window was 0.35 s wide and CI overran it (rotation 4.6 turns > 4 pi).
  const smoothclip::TimingAnimation timing{20000, 0, 0, 1, 1, 2};
  XCTAssertTrue([host smoothClipAnimateTiming:target animation:timing
      animationId:12346 sharedBeginTime:CACurrentMediaTime() - 8.0]);
  [CATransaction flush];
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  const auto visible = [host smoothClipCurrentPresentation];
  // Beyond one full turn: the read is unwrapped against the run, not the
  // matrix's (-pi, pi]. Below the target: the run is still in flight.
  XCTAssertGreaterThan(visible.rotation, 2 * M_PI);
  XCTAssertLessThan(visible.rotation, 8 * M_PI);
  XCTAssertGreaterThan(visible.opacity, 0);
  XCTAssertEqual([host hitTest:CGPointMake(70, 70) withEvent:nil], child);
  XCTAssertLessThan(visible.opacity, 1);
  [host smoothClipApplyPresentation:visible];
  const auto frozen = [host smoothClipCurrentPresentation];
  XCTAssertEqualWithAccuracy(frozen.rotation, visible.rotation, 1e-9);
  XCTAssertEqualWithAccuracy(frozen.opacity, visible.opacity, 1e-6);
  window.hidden = YES;
}

- (void)testRenderedRotatedFadeKeepsOverlappingChildrenInOneGroup {
  UIWindow *window = TestWindow();
  SmoothClipView *host = DisplayableView(window, CGRectMake(0, 0, 100, 100));
  UIView *content = [host valueForKey:@"contentContainer"];
  UIView *red = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 100, 100)];
  red.backgroundColor = UIColor.redColor;
  UIView *blue = [[UIView alloc] initWithFrame:CGRectMake(40, 0, 60, 100)];
  blue.backgroundColor = UIColor.blueColor;
  [content addSubview:red];
  [content addSubview:blue];
  auto frame = Presentation(20, 40, 60, 20, 0);
  frame.rotation = M_PI_2;
  frame.opacity = 0.5;
  [host smoothClipApplyPresentation:frame];
  uint8_t pixels[100 * 100 * 4] = {};
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(pixels, 100, 100, 8, 400, space,
      kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGContextTranslateCTM(context, 0, 100);
  CGContextScaleCTM(context, 1, -1);
  [host.layer renderInContext:context];
  XCTAssertEqual(pixels[(50 * 100 + 25) * 4 + 3], 0);
  XCTAssertEqualWithAccuracy(pixels[(25 * 100 + 50) * 4 + 3], 128, 1);
  XCTAssertEqualWithAccuracy(pixels[(60 * 100 + 50) * 4 + 3], 128, 1);
  CGImageRef image = CGBitmapContextCreateImage(context);
  XCTAttachment *attachment = [XCTAttachment attachmentWithImage:[UIImage imageWithCGImage:image]];
  attachment.name = @"Rotated group opacity";
  attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
  [self addAttachment:attachment];
  CGImageRelease(image);
  CGContextRelease(context);
  CGColorSpaceRelease(space);
}

// Alpha of a baked tile on its middle row, `distance` pt outside the shape
// (negative: inside), for a `side` pt tile with a `margin` pt border.
static CGFloat TileAlphaOutsideShape(
    CGImageRef image, CGFloat side, CGFloat margin, CGFloat distance) {
  const size_t width = CGImageGetWidth(image);
  const size_t height = CGImageGetHeight(image);
  const CGFloat scale = width / side;
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(
      NULL, width, height, 8, 0, space,
      kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(space);
  CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
  const uint8_t *data = (const uint8_t *)CGBitmapContextGetData(context);
  const size_t bytesPerRow = CGBitmapContextGetBytesPerRow(context);
  const size_t x = (size_t)MIN(
      (CGFloat)(width - 1), MAX(0, round((margin - distance) * scale)));
  const CGFloat alpha = data[(height / 2) * bytesPerRow + x * 4 + 3] / 255.0;
  CGContextRelease(context);
  return alpha;
}

- (void)testBakedShadowStretchesOneTileAndSwapsItInSteps {
  constexpr uint64_t driverId = 99084;
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 400, 400));
  [host setValue:@(driverId) forKey:@"driverId"];
  [host setValue:@YES forKey:@"bakedShadows"];
  const smoothclip::Shadow shadow = BoxShadow(0.25, 0, 2, 16, 0, 0, 0, 0);
  const smoothclip::Presentation card = PresentationValue(
      20, 250, 360, 100, 20, 20, 20, 20,
      smoothclip::ClipCurve::Continuous, 0, 0, 1, shadow);
  smoothclip::registerView(driverId, host, card);

  CALayer *shadowLayer = [host valueForKey:@"shadowLayer"];
  XCTAssertNotNil(shadowLayer);
  XCTAssertNotNil(shadowLayer.contents);
  XCTAssertTrue(shadowLayer.shadowPath == NULL);
  XCTAssertEqualWithAccuracy(shadowLayer.shadowOpacity, 0, 1e-9);
  XCTAssertEqualWithAccuracy(shadowLayer.opacity, 0.25, 1e-6);
  // The tile holds the blurred shape itself: opaque at the centre, half
  // covered at the shape edge, and a Gaussian tail (sigma 8 pt for blur 16,
  // the profile Core Animation gives `shadowRadius` 8) gone inside the 24 pt
  // margin. Rendering a shadowPath-only layer through `renderInContext:`
  // left every pixel at 0, and a baked host drew no shadow at all.
  CGImageRef image = (__bridge CGImageRef)shadowLayer.contents;
  XCTAssertGreaterThan(TileAlphaOutsideShape(image, 138, 24, -45), 0.97);
  XCTAssertEqualWithAccuracy(TileAlphaOutsideShape(image, 138, 24, 0), 0.5, 0.1);
  XCTAssertEqualWithAccuracy(TileAlphaOutsideShape(image, 138, 24, 8), 0.16, 0.05);
  XCTAssertLessThan(TileAlphaOutsideShape(image, 138, 24, 16), 0.03);
  XCTAssertLessThan(TileAlphaOutsideShape(image, 138, 24, 24), 0.005);
  // Shape 360 x 100 offset (0, 2), plus a 24 pt margin (1.5 x blur 16) per side.
  XCTAssertEqualWithAccuracy(shadowLayer.bounds.size.width, 360 + 48, 1e-6);
  XCTAssertEqualWithAccuracy(shadowLayer.bounds.size.height, 100 + 48, 1e-6);
  XCTAssertEqualWithAccuracy(shadowLayer.position.x, 20 + 180, 1e-6);
  XCTAssertEqualWithAccuracy(shadowLayer.position.y, 250 + 2 + 50, 1e-6);
  // Corner slices of margin + radius + margin = 68 pt in a 138 pt tile.
  XCTAssertEqualWithAccuracy(
      shadowLayer.contentsCenter.origin.x, 68.0 / 138.0, 1e-6);
  XCTAssertEqualWithAccuracy(
      shadowLayer.contentsCenter.size.width, 2.0 / 138.0, 1e-6);
  id tile = shadowLayer.contents;

  // A run that keeps the radius animates the tile layer's frame only.
  const smoothclip::Presentation full = PresentationValue(
      0, 0, 400, 400, 20, 20, 20, 20,
      smoothclip::ClipCurve::Continuous, 0, 0, 1, shadow);
  const smoothclip::TimingAnimation timing{400, 1.0 / 3.0, 1, 2.0 / 3.0, 1, 2};
  int32_t groupId = smoothclip::animateTimingGroup(
      7094, {GroupEntry(driverId, true, card, full)}, timing);
  XCTAssertGreaterThan(groupId, 0);
  CAAnimationGroup *shadowGroup = (CAAnimationGroup *)[shadowLayer
      animationForKey:@"smoothClip.shadow"];
  XCTAssertNotNil(shadowGroup);
  NSMutableSet<NSString *> *keyPaths = [NSMutableSet set];
  for (CAPropertyAnimation *animation in shadowGroup.animations) {
    [keyPaths addObject:animation.keyPath];
  }
  XCTAssertEqualObjects(
      keyPaths, ([NSSet setWithArray:@[ @"bounds", @"position" ]]));
  XCTAssertTrue(shadowLayer.contents == tile);
  XCTAssertTrue(shadowLayer.shadowPath == NULL);
  smoothclip::cancelAnimationGroup(
      groupId, smoothclip::GroupCancelBehavior::Finish);

  // A run that changes the radius swaps tiles in 4 pt steps along the way.
  // On a cold cache only the target bakes inside the install; the steps in
  // between (24, 28, 32) are requested off the frame, and the run shows the
  // target tile throughout rather than a tighter tile under a rounder clip.
  const smoothclip::Presentation rounder = PresentationValue(
      0, 0, 400, 400, 36, 36, 36, 36,
      smoothclip::ClipCurve::Continuous, 0, 0, 1, shadow);
  SmoothClipBakePendingShadowTilesForTesting();
  const NSUInteger bakedBefore = SmoothClipShadowTileBakeCountForTesting();
  groupId = smoothclip::animateTimingGroup(
      7095, {GroupEntry(driverId, true, full, rounder)}, timing);
  XCTAssertGreaterThan(groupId, 0);
  XCTAssertEqual(SmoothClipShadowTileBakeCountForTesting(), bakedBefore + 1);
  XCTAssertEqual(SmoothClipPendingShadowTileCountForTesting(), 3u);
  shadowGroup = (CAAnimationGroup *)[shadowLayer
      animationForKey:@"smoothClip.shadow"];
  XCTAssertNotNil(shadowGroup);
  CAKeyframeAnimation *contents = nil;
  for (CAPropertyAnimation *animation in shadowGroup.animations) {
    if ([animation.keyPath isEqualToString:@"contents"]) {
      contents = (CAKeyframeAnimation *)animation;
    }
  }
  XCTAssertNil(contents);
  XCTAssertTrue(shadowLayer.contents != tile);
  smoothclip::cancelAnimationGroup(
      groupId, smoothclip::GroupCancelBehavior::Finish);

  // With every step cached the same run shows tiles 24 (from the first
  // frame), 28, 32 and 36, each where the radius crosses its step.
  SmoothClipBakePendingShadowTilesForTesting();
  XCTAssertEqual(SmoothClipShadowTileBakeCountForTesting(), bakedBefore + 4);
  [host smoothClipApplyPresentation:full];
  XCTAssertTrue(shadowLayer.contents == tile);
  groupId = smoothclip::animateTimingGroup(
      7098, {GroupEntry(driverId, true, full, rounder)}, timing);
  XCTAssertGreaterThan(groupId, 0);
  XCTAssertEqual(SmoothClipShadowTileBakeCountForTesting(), bakedBefore + 4);
  shadowGroup = (CAAnimationGroup *)[shadowLayer
      animationForKey:@"smoothClip.shadow"];
  XCTAssertNotNil(shadowGroup);
  contents = nil;
  for (CAPropertyAnimation *animation in shadowGroup.animations) {
    if ([animation.keyPath isEqualToString:@"contents"]) {
      contents = (CAKeyframeAnimation *)animation;
    }
  }
  XCTAssertNotNil(contents);
  XCTAssertEqual(contents.values.count, 4u);
  XCTAssertEqualObjects(contents.calculationMode, kCAAnimationDiscrete);
  // Discrete key times bracket the values: one more than the values, from 0
  // to 1, so each swap lands where the radius crosses its step rather than on
  // an even grid.
  XCTAssertEqual(contents.keyTimes.count, 5u);
  XCTAssertEqualWithAccuracy(contents.keyTimes[0].doubleValue, 0, 1e-9);
  XCTAssertGreaterThan(contents.keyTimes[1].doubleValue, 0);
  XCTAssertLessThan(contents.keyTimes[2].doubleValue, contents.keyTimes[3].doubleValue);
  XCTAssertLessThan(contents.keyTimes[3].doubleValue, 1);
  XCTAssertEqualWithAccuracy(contents.keyTimes[4].doubleValue, 1, 1e-9);
  // The model already holds the target tile.
  XCTAssertTrue(contents.values.lastObject == shadowLayer.contents);
  XCTAssertTrue(shadowLayer.shadowPath == NULL);
  smoothclip::cancelAnimationGroup(
      groupId, smoothclip::GroupCancelBehavior::Finish);

  // A shape with no room for two corner slices (2 x (24 + 20) = 88 pt on a
  // side) keeps the blur path for that frame; a larger one takes the tile
  // again.
  [host smoothClipApplyPresentation:PresentationValue(
      20, 250, 60, 60, 20, 20, 20, 20,
      smoothclip::ClipCurve::Continuous, 0, 0, 1, shadow)];
  XCTAssertNil(shadowLayer.contents);
  XCTAssertTrue(shadowLayer.shadowPath != NULL);
  // (`rounder`, not `full`: the blur-path step below applies `full` and must
  // see a change, an identical presentation is a no-op write.)
  [host smoothClipApplyPresentation:rounder];
  XCTAssertNotNil(shadowLayer.contents);
  XCTAssertTrue(shadowLayer.shadowPath == NULL);

  // Back to the blur path: the tile goes, the shadowPath returns.
  [host setValue:@NO forKey:@"bakedShadows"];
  [host smoothClipApplyPresentation:full];
  XCTAssertNil(shadowLayer.contents);
  XCTAssertTrue(shadowLayer.shadowPath != NULL);
  XCTAssertEqualWithAccuracy(shadowLayer.opacity, 1, 1e-9);
  XCTAssertEqualWithAccuracy(shadowLayer.shadowOpacity, 1, 1e-9);

  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

- (void)testBakedShadowMissesShowTheNearestTileAndBakeOffTheFrame {
  constexpr uint64_t driverId = 99085;
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 400, 400));
  [host setValue:@(driverId) forKey:@"driverId"];
  [host setValue:@YES forKey:@"bakedShadows"];
  // A colour no other test bakes, so this cache line starts cold.
  const smoothclip::Shadow shadow = BoxShadow(0.25, 0, 2, 16, 0, 0.2, 0, 0);
  const smoothclip::Presentation card = PresentationValue(
      20, 100, 360, 200, 20, 20, 20, 20,
      smoothclip::ClipCurve::Continuous, 0, 0, 1, shadow);
  SmoothClipBakePendingShadowTilesForTesting();
  const NSUInteger bakedBefore = SmoothClipShadowTileBakeCountForTesting();
  smoothclip::registerView(driverId, host, card);
  CALayer *shadowLayer = [host valueForKey:@"shadowLayer"];
  XCTAssertNotNil(shadowLayer);
  // Nothing near to show at mount: the first tile bakes now.
  XCTAssertEqual(SmoothClipShadowTileBakeCountForTesting(), bakedBefore + 1);
  id first = shadowLayer.contents;
  XCTAssertNotNil(first);

  // A frame two steps rounder (a drag crossing steps): the cached tile
  // stands in and the exact one is requested, not baked inside the frame.
  const smoothclip::Presentation rounder = PresentationValue(
      20, 100, 360, 200, 28, 28, 28, 28,
      smoothclip::ClipCurve::Continuous, 0, 0, 1, shadow);
  [host smoothClipApplyPresentation:rounder];
  XCTAssertEqual(SmoothClipShadowTileBakeCountForTesting(), bakedBefore + 1);
  XCTAssertTrue(shadowLayer.contents == first);
  XCTAssertEqual(SmoothClipPendingShadowTileCountForTesting(), 1u);

  // Once it lands the model takes it without another write from the caller.
  SmoothClipBakePendingShadowTilesForTesting();
  XCTAssertEqual(SmoothClipShadowTileBakeCountForTesting(), bakedBefore + 2);
  XCTAssertNotNil(shadowLayer.contents);
  XCTAssertTrue(shadowLayer.contents != first);
  // Exact from now on: the same frame bakes and requests nothing.
  id exact = shadowLayer.contents;
  [host smoothClipApplyPresentation:rounder];
  XCTAssertTrue(shadowLayer.contents == exact);
  XCTAssertEqual(SmoothClipShadowTileBakeCountForTesting(), bakedBefore + 2);
  XCTAssertEqual(SmoothClipPendingShadowTileCountForTesting(), 0u);

  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

- (void)testBackdropFollowsEveryWriteAndRunOnTheClipEpoch {
  constexpr uint64_t driverId = 99086;
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 400, 400));
  [host setValue:@(driverId) forKey:@"driverId"];
  smoothclip::Presentation initial = PresentationValue(
      20, 250, 360, 100, 20, 20, 20, 20,
      smoothclip::ClipCurve::Continuous, 0, 0, 1);
  initial.backdropTranslateX = -10;
  initial.backdropTranslateY = 30;
  smoothclip::registerView(driverId, host, initial);

  // A backdrop bound after the host adopts the driver's model.
  SmoothClipBackdropView *backdrop =
      [[SmoothClipBackdropView alloc] initWithFrame:CGRectMake(0, 0, 400, 400)];
  [window addSubview:backdrop];
  smoothclip::registerBackdropView(driverId, backdrop);
  CALayer *content = ((UIView *)[backdrop valueForKey:@"content"]).layer;
  XCTAssertEqualWithAccuracy(content.transform.m41, -10, 1e-6);
  XCTAssertEqualWithAccuracy(content.transform.m42, 30, 1e-6);

  // Fabric lays the view out after it set the props that bound it. A layout
  // pass under a non-zero channel must leave the content centred in the
  // view with the translation intact (a frame write would fold the
  // translation into the position through the transform's inverse).
  facebook::react::LayoutMetrics metrics;
  metrics.frame = facebook::react::Rect{
      facebook::react::Point{0, 0}, facebook::react::Size{400, 400}};
  [backdrop updateLayoutMetrics:metrics
               oldLayoutMetrics:facebook::react::LayoutMetrics{}];
  XCTAssertEqualWithAccuracy(content.position.x, 200, 1e-6);
  XCTAssertEqualWithAccuracy(content.position.y, 200, 1e-6);
  XCTAssertEqualWithAccuracy(content.transform.m41, -10, 1e-6);
  XCTAssertEqualWithAccuracy(content.transform.m42, 30, 1e-6);
  XCTAssertEqualWithAccuracy(content.frame.origin.x, -10, 1e-6);
  XCTAssertEqualWithAccuracy(content.frame.origin.y, 30, 1e-6);

  // A setFrame moves it in the same write as the clip.
  smoothclip::Presentation frame = initial;
  frame.backdropTranslateX = 5;
  frame.backdropTranslateY = -6;
  smoothclip::setPresentation(driverId, frame, true);
  XCTAssertEqualWithAccuracy(content.transform.m41, 5, 1e-6);
  XCTAssertEqualWithAccuracy(content.transform.m42, -6, 1e-6);
  XCTAssertNil([content animationForKey:@"smoothClip.backdrop"]);

  // A run adds a translation group on the clip's epoch, its install, with the
  // model already at the target.
  smoothclip::Presentation target = PresentationValue(
      0, 0, 400, 400, 20, 20, 20, 20,
      smoothclip::ClipCurve::Continuous, 0, 0, 1);
  target.backdropTranslateX = 0;
  target.backdropTranslateY = 0;
  const smoothclip::TimingAnimation timing{400, 1.0 / 3.0, 1, 2.0 / 3.0, 1, 2};
  const CFTimeInterval before = CACurrentMediaTime();
  int32_t groupId = smoothclip::animateTimingGroup(
      7100, {GroupEntry(driverId, true, frame, target)}, timing);
  const CFTimeInterval after = CACurrentMediaTime();
  XCTAssertGreaterThan(groupId, 0);
  CAAnimationGroup *group =
      (CAAnimationGroup *)[content animationForKey:@"smoothClip.backdrop"];
  XCTAssertNotNil(group);
  const CFTimeInterval backdropBegin =
      [content convertTime:group.beginTime toLayer:nil];
  XCTAssertGreaterThanOrEqual(backdropBegin, before);
  XCTAssertLessThanOrEqual(backdropBegin, after);
  CALayer *clipLayer = ((UIView *)[host valueForKey:@"clipContainer"]).layer;
  XCTAssertEqualWithAccuracy(
      backdropBegin,
      [clipLayer
          convertTime:[clipLayer animationForKey:@"smoothClip.geometry"]
                          .beginTime
              toLayer:nil],
      1e-9);
  XCTAssertEqualWithAccuracy(group.duration, 0.4, 1e-9);
  NSMutableSet<NSString *> *keyPaths = [NSMutableSet set];
  for (CAPropertyAnimation *animation in group.animations) {
    [keyPaths addObject:animation.keyPath];
    if ([animation.keyPath isEqualToString:@"transform.translation.x"]) {
      XCTAssertEqualWithAccuracy(
          ((NSNumber *)((CABasicAnimation *)animation).fromValue).doubleValue,
          5, 1e-6);
    }
  }
  XCTAssertEqualObjects(
      keyPaths,
      ([NSSet setWithArray:@[
        @"transform.translation.x", @"transform.translation.y"
      ]]));
  XCTAssertEqualWithAccuracy(content.transform.m41, 0, 1e-6);
  XCTAssertEqualWithAccuracy(content.transform.m42, 0, 1e-6);

  // Finishing the run leaves the target and no animation behind.
  smoothclip::cancelAnimationGroup(
      groupId, smoothclip::GroupCancelBehavior::Finish);
  XCTAssertNil([content animationForKey:@"smoothClip.backdrop"]);
  XCTAssertEqualWithAccuracy(content.transform.m41, 0, 1e-6);

  // A freeze seals the backdrop where it is and reports the channel.
  groupId = smoothclip::animateTimingGroup(
      7101, {GroupEntry(driverId, true, target, frame)}, timing);
  XCTAssertGreaterThan(groupId, 0);
  const std::vector<smoothclip::DriverSnapshot> frozen =
      smoothclip::cancelAnimationGroup(
          groupId, smoothclip::GroupCancelBehavior::Freeze);
  XCTAssertEqual(frozen.size(), 1u);
  XCTAssertNil([content animationForKey:@"smoothClip.backdrop"]);
  XCTAssertEqualWithAccuracy(
      frozen[0].presentation.backdropTranslateX, content.transform.m41, 1e-6);
  XCTAssertEqualWithAccuracy(
      frozen[0].presentation.backdropTranslateY, content.transform.m42, 1e-6);

  smoothclip::unregisterBackdropView(driverId, backdrop);
  [backdrop removeFromSuperview];
  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

// The media time the host's installed run begins at.
static CFTimeInterval InstalledBeginTime(SmoothClipView *host) {
  CALayer *layer = ((UIView *)[host valueForKey:@"clipContainer"]).layer;
  CAAnimation *geometry = [layer animationForKey:@"smoothClip.geometry"];
  return geometry == nil ? NAN
                         : [layer convertTime:geometry.beginTime toLayer:nil];
}

// Lets `seconds` of media time pass with what was installed committed. A
// group run begins at its install, so a run partway through takes real time.
static void Elapse(double seconds) {
  [CATransaction flush];
  usleep(static_cast<useconds_t>(seconds * 1e6));
}

// The media time every layer of the host's run begins at: the clip's and the
// content's, which must agree.
- (CFTimeInterval)sharedBeginTimeOf:(SmoothClipView *)host {
  CALayer *clip = ((UIView *)[host valueForKey:@"clipContainer"]).layer;
  CALayer *content = ((UIView *)[host valueForKey:@"contentContainer"]).layer;
  CAAnimation *geometry = [clip animationForKey:@"smoothClip.geometry"];
  CAAnimation *contentGroup = [content animationForKey:@"smoothClip.content"];
  XCTAssertNotNil(geometry);
  XCTAssertNotNil(contentGroup);
  const CFTimeInterval begin = [clip convertTime:geometry.beginTime toLayer:nil];
  XCTAssertEqualWithAccuracy(
      [content convertTime:contentGroup.beginTime toLayer:nil], begin, 1e-9);
  return begin;
}

// A group run begins at its install, whatever frame stamp the caller passed:
// none, the vsync just passed or still to come, far ahead, stale. Begun at a
// stamp ahead, the first frame drawn would repeat the start; at one behind,
// it would skip ahead of the frame on screen.
- (void)testAGroupBeginsAtItsInstallWhateverItsStamp {
  constexpr uint64_t driverId = 99081;
  UIWindow *window = TestWindow();
  SmoothClipView *host =
      DisplayableView(window, CGRectMake(0, 0, 200, 200));
  [host setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation initial = PresentationValue(
      0, 0, 50, 50, 12, 12, 12, 12,
      smoothclip::ClipCurve::Continuous, 0, 0, 1);
  const smoothclip::Presentation target = PresentationValue(
      20, 30, 140, 100, 20, 20, 20, 20,
      smoothclip::ClipCurve::Continuous, 8, -6, 0.7);
  smoothclip::registerView(driverId, host, initial);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  for (const double offset :
       {static_cast<double>(NAN), -1.0 / 60.0, 1.0 / 60.0, 5.0, -0.5, -5.0}) {
    const CFTimeInterval before = CACurrentMediaTime();
    const int32_t groupId = smoothclip::animateTimingGroup(
        7091, {GroupEntry(driverId, true, initial, target)}, timing, 0,
        before + offset);
    const CFTimeInterval after = CACurrentMediaTime();
    XCTAssertGreaterThan(groupId, 0);
    const CFTimeInterval begin = [self sharedBeginTimeOf:host];
    XCTAssertGreaterThanOrEqual(begin, before, @"offset %f", offset);
    XCTAssertLessThanOrEqual(begin, after, @"offset %f", offset);
    smoothclip::cancelAnimationGroup(
        groupId, smoothclip::GroupCancelBehavior::Freeze);
  }

  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

// A group that waits for its host (laid out, not yet in a window) begins at
// the install that host's attach makes, not at the call's stamp: it starts
// from its start, with its whole duration ahead.
- (void)testAPendingGroupBeginsAtTheInstallItWaitedFor {
  constexpr uint64_t driverId = 99082;
  SmoothClipView *host =
      [[SmoothClipView alloc] initWithFrame:CGRectMake(0, 0, 120, 120)];
  facebook::react::LayoutMetrics metrics;
  metrics.frame = facebook::react::Rect{
      facebook::react::Point{0, 0}, facebook::react::Size{120, 120}};
  [host updateLayoutMetrics:metrics
           oldLayoutMetrics:facebook::react::LayoutMetrics{}];
  [host setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation initial = Presentation(0, 0, 40, 40, 20, 5, 6);
  const smoothclip::Presentation target =
      Presentation(0, 0, 100, 100, 12, -20, -30);
  smoothclip::registerView(driverId, host, initial);
  const smoothclip::TimingAnimation timing{250, 0.42, 0, 0.58, 1, 2};

  const int32_t groupId = smoothclip::animateTimingGroup(
      7094, {GroupEntry(driverId, true, initial, target)}, timing, 0,
      CACurrentMediaTime() - 1.0 / 60.0);
  XCTAssertGreaterThan(groupId, 0);
  XCTAssertTrue(isnan(InstalledBeginTime(host)));
  usleep(50000);

  UIWindow *window = TestWindow();
  const CFTimeInterval before = CACurrentMediaTime();
  [window addSubview:host];
  const CFTimeInterval after = CACurrentMediaTime();
  const CFTimeInterval begin = [self sharedBeginTimeOf:host];
  XCTAssertGreaterThanOrEqual(begin, before);
  XCTAssertLessThanOrEqual(begin, after);

  smoothclip::cancelAnimationGroup(
      groupId, smoothclip::GroupCancelBehavior::Freeze);
  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

#pragma mark - Flights (docs/flight-spec.md)

// A flight host as Fabric mounts it: laid out at `frame` in `parent`, with
// the codegen props for its driver, its initial presentation and `flight`.
static SmoothClipView *FlightHost(
    UIView *parent,
    CGRect frame,
    uint64_t driverId,
    const char *tag,
    const smoothclip::Presentation &initial) {
  SmoothClipView *view = [[SmoothClipView alloc] initWithFrame:frame];
  facebook::react::LayoutMetrics metrics;
  metrics.frame = facebook::react::Rect{
      facebook::react::Point{frame.origin.x, frame.origin.y},
      facebook::react::Size{frame.size.width, frame.size.height}};
  [view updateLayoutMetrics:metrics
           oldLayoutMetrics:facebook::react::LayoutMetrics{}];
  [parent addSubview:view];
  auto props = std::make_shared<facebook::react::SmoothClipViewProps>();
  props->driverId = driverId;
  props->initialClipX = initial.clip.x;
  props->initialClipY = initial.clip.y;
  props->initialClipWidth = initial.clip.width;
  props->initialClipHeight = initial.clip.height;
  props->initialClipTopLeftRadius = initial.clip.radius;
  props->initialClipTopRightRadius = initial.clip.radius;
  props->initialClipBottomRightRadius = initial.clip.radius;
  props->initialClipBottomLeftRadius = initial.clip.radius;
  props->initialClipCurve = 0;
  props->initialContentTranslateX = initial.contentTranslateX;
  props->initialContentTranslateY = initial.contentTranslateY;
  props->initialContentScale = initial.contentScale;
  props->flightEnabled = true;
  props->flightTag = tag;
  [view updateProps:props oldProps:facebook::react::Props::Shared{}];
  return view;
}

static void SetFlightTargetProps(
    SmoothClipFlightTargetView *target,
    const char *tag,
    bool ready) {
  auto props =
      std::make_shared<facebook::react::SmoothClipFlightTargetProps>();
  props->flightTag = tag;
  props->ready = ready;
  [target updateProps:props oldProps:facebook::react::Props::Shared{}];
}

// `<SmoothClipFlightTarget tag ready>`, attached to `parent` when given.
static SmoothClipFlightTargetView *FlightTarget(
    UIView *parent,
    CGRect frame,
    const char *tag,
    bool ready = true) {
  SmoothClipFlightTargetView *target =
      [[SmoothClipFlightTargetView alloc] initWithFrame:frame];
  SetFlightTargetProps(target, tag, ready);
  if (parent != nil) [parent addSubview:target];
  return target;
}

// The target's inner container: the only view the flight hides.
static UIView *TargetContent(SmoothClipFlightTargetView *target) {
  return target.subviews.firstObject;
}

static UIView *PresentationContainer(SmoothClipView *host) {
  return (UIView *)[host valueForKey:@"presentationContainer"];
}

// Lets landings scheduled after a run ends (dispatch to main) run.
static void DrainMainQueue(void) {
  [[NSRunLoop mainRunLoop]
      runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}

static const smoothclip::TimingAnimation kFlightTiming{
    5000, 0.42, 0, 0.58, 1, 2};

- (void)testFlightLiftDrawsTheCarrierThroughTheHostTransform {
  constexpr uint64_t driverId = 99201;
  UIWindow *window = TestWindow();
  // A press-scale or a scaled presenter: every point of the host shows at
  // 0.9 about the container's centre.
  UIView *scaled = [[UIView alloc] initWithFrame:window.bounds];
  scaled.transform = CGAffineTransformMakeScale(0.9, 0.9);
  [window addSubview:scaled];
  const smoothclip::Presentation rest = Presentation(0, 0, 200, 150, 12);
  SmoothClipView *host = FlightHost(
      scaled, CGRectMake(30, 60, 200, 150), driverId, "", rest);
  const smoothclip::Presentation target = Presentation(-10, -20, 300, 260, 0);

  const int32_t groupId = smoothclip::animateTimingGroup(
      7201, {GroupEntry(driverId, false, rest, target)}, kFlightTiming);
  XCTAssertGreaterThan(groupId, 0);

  UIView *presentation = PresentationContainer(host);
  UIView *carrier = presentation.superview;
  XCTAssertNotEqual(carrier, host);
  UIView *flightLayer = carrier.superview;
  XCTAssertEqual(flightLayer.superview, window);
  XCTAssertEqual(flightLayer.layer.zPosition, 1000);
  XCTAssertTrue(flightLayer.accessibilityElementsHidden);
  XCTAssertFalse(flightLayer.userInteractionEnabled);

  const CGAffineTransform transform = carrier.layer.affineTransform;
  const CGPoint origin = [host convertPoint:CGPointZero toView:window];
  XCTAssertEqualWithAccuracy(origin.x, 47, 1e-9);
  XCTAssertEqualWithAccuracy(origin.y, 94, 1e-9);
  XCTAssertEqualWithAccuracy(transform.a, 0.9, 1e-9);
  XCTAssertEqualWithAccuracy(transform.d, 0.9, 1e-9);
  XCTAssertEqualWithAccuracy(transform.b, 0, 1e-9);
  XCTAssertEqualWithAccuracy(transform.c, 0, 1e-9);
  XCTAssertEqualWithAccuracy(transform.tx, origin.x, 1e-9);
  XCTAssertEqualWithAccuracy(transform.ty, origin.y, 1e-9);
  // Every host point draws where it drew in the host: no jump at the lift.
  for (const CGPoint point :
       {CGPointMake(0, 0), CGPointMake(17, 23), CGPointMake(200, 150)}) {
    const CGPoint flying = [carrier convertPoint:point toView:window];
    const CGPoint resting = [host convertPoint:point toView:window];
    XCTAssertEqualWithAccuracy(flying.x, resting.x, 1e-9);
    XCTAssertEqualWithAccuracy(flying.y, resting.y, 1e-9);
  }

  smoothclip::cancelAnimationGroup(
      groupId, smoothclip::GroupCancelBehavior::Freeze);
  DrainMainQueue();
  XCTAssertEqual(presentation.superview, host);
  XCTAssertNil(carrier.superview);
  smoothclip::destroyDriver(driverId);
}

- (void)testWindowSpaceTargetLandsOnTheWindowRect {
  constexpr uint64_t driverId = 99202;
  UIWindow *window = TestWindow();
  UIView *scaled = [[UIView alloc] initWithFrame:window.bounds];
  scaled.transform = CGAffineTransformMakeScale(0.9, 0.9);
  [window addSubview:scaled];
  const smoothclip::Presentation rest = Presentation(0, 0, 200, 150, 12);
  SmoothClipView *host = FlightHost(
      scaled, CGRectMake(30, 60, 200, 150), driverId, "", rest);
  const CGRect windowRect = CGRectMake(40, 100, 240, 180);
  smoothclip::Presentation windowTarget = Presentation(
      windowRect.origin.x, windowRect.origin.y, windowRect.size.width,
      windowRect.size.height, 18, windowRect.origin.x, windowRect.origin.y);
  smoothclip::GroupMotionEntry entry =
      GroupEntry(driverId, false, rest, windowTarget);
  entry.targetInWindow = true;

  const int32_t groupId =
      smoothclip::animateTimingGroup(7202, {entry}, kFlightTiming);
  XCTAssertGreaterThan(groupId, 0);
  [host smoothClipAnimationDidStopWithDriverId:driverId
                                   animationId:groupId
                                      finished:YES];
  // No target: the flight returns into the host, which keeps where it landed.
  XCTAssertEqual(PresentationContainer(host).superview, host);
  const smoothclip::Presentation landed = smoothclip::snapshotCurrent(driverId);
  const CGRect onScreen = [host
      convertRect:CGRectMake(landed.clip.x, landed.clip.y, landed.clip.width,
                             landed.clip.height)
           toView:window];
  XCTAssertEqualWithAccuracy(onScreen.origin.x, windowRect.origin.x, 1e-6);
  XCTAssertEqualWithAccuracy(onScreen.origin.y, windowRect.origin.y, 1e-6);
  XCTAssertEqualWithAccuracy(onScreen.size.width, windowRect.size.width, 1e-6);
  XCTAssertEqualWithAccuracy(onScreen.size.height, windowRect.size.height, 1e-6);
  XCTAssertEqualWithAccuracy(landed.clip.radius, 18 / 0.9, 1e-6);
  XCTAssertEqualWithAccuracy(landed.contentScale, 1 / 0.9, 1e-6);

  // A window-space frame (setFrame) resolves the same way.
  smoothclip::BatchEntry frame{driverId, windowTarget};
  frame.inWindow = true;
  XCTAssertTrue(smoothclip::setPresentationBatch({frame}));
  const smoothclip::Presentation set = smoothclip::snapshotCurrent(driverId);
  XCTAssertEqualWithAccuracy(set.clip.x, landed.clip.x, 1e-6);
  XCTAssertEqualWithAccuracy(set.clip.y, landed.clip.y, 1e-6);

  // A rotated host cannot express a window rect: the whole call rejects.
  scaled.transform = CGAffineTransformMakeRotation(0.2);
  XCTAssertEqual(smoothclip::animateTimingGroup(7203, {entry}, kFlightTiming), 0);
  XCTAssertFalse(smoothclip::setPresentationBatch({frame}));
  // So does a driver with no host.
  smoothclip::GroupMotionEntry orphan =
      GroupEntry(99299, true, rest, windowTarget);
  orphan.targetInWindow = true;
  XCTAssertEqual(smoothclip::animateTimingGroup(7204, {orphan}, kFlightTiming), 0);
  smoothclip::destroyDriver(driverId);
}

- (void)testHandoffRevealsTheTargetAndRestsTheHost {
  constexpr uint64_t driverId = 99203;
  UIWindow *window = TestWindow();
  const smoothclip::Presentation rest = Presentation(0, 0, 160, 120, 16);
  SmoothClipView *host = FlightHost(
      window, CGRectMake(20, 300, 160, 120), driverId, "flight-a", rest);
  const smoothclip::Presentation landing =
      Presentation(-20, -300, 400, 500, 0, -20, -300);

  const int32_t groupId = smoothclip::animateTimingGroup(
      7205, {GroupEntry(driverId, false, rest, landing)}, kFlightTiming);
  XCTAssertGreaterThan(groupId, 0);
  UIView *presentation = PresentationContainer(host);
  UIView *carrier = presentation.superview;
  XCTAssertNotEqual(carrier, host);

  // The destination mounts while the flight is airborne: it mounts covered.
  SmoothClipFlightTargetView *target =
      FlightTarget(window, CGRectMake(0, 0, 400, 500), "flight-a");
  XCTAssertTrue(target.flightCovered);
  XCTAssertTrue(TargetContent(target).hidden);
  XCTAssertFalse(target.hidden);

  [host smoothClipAnimationDidStopWithDriverId:driverId
                                   animationId:groupId
                                      finished:YES];
  XCTAssertFalse(target.flightCovered);
  XCTAssertFalse(TargetContent(target).hidden);
  XCTAssertEqual(presentation.superview, host);
  XCTAssertNil(carrier.superview);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));
  // The host is back at rest under its target, in the registry and on screen.
  const smoothclip::Presentation settled = smoothclip::snapshotCurrent(driverId);
  XCTAssertEqualWithAccuracy(settled.clip.x, rest.clip.x, 1e-9);
  XCTAssertEqualWithAccuracy(settled.clip.y, rest.clip.y, 1e-9);
  XCTAssertEqualWithAccuracy(settled.clip.width, rest.clip.width, 1e-9);
  XCTAssertEqualWithAccuracy(settled.clip.radius, rest.clip.radius, 1e-9);
  const smoothclip::Presentation shown = [host smoothClipCurrentPresentation];
  XCTAssertEqualWithAccuracy(shown.clip.width, rest.clip.width, 1e-9);
  smoothclip::destroyDriver(driverId);
}

- (void)testTheWayBackStartsFromTheLandedPresentation {
  constexpr uint64_t driverId = 99204;
  UIWindow *window = TestWindow();
  const smoothclip::Presentation rest = Presentation(0, 0, 160, 120, 16);
  SmoothClipView *host = FlightHost(
      window, CGRectMake(20, 300, 160, 120), driverId, "flight-b", rest);
  const smoothclip::Presentation landing =
      Presentation(-20, -300, 400, 500, 0, -20, -300);
  int32_t groupId = smoothclip::animateTimingGroup(
      7206, {GroupEntry(driverId, false, rest, landing)}, kFlightTiming);
  SmoothClipFlightTargetView *target =
      FlightTarget(window, CGRectMake(0, 0, 400, 500), "flight-b");
  [host smoothClipAnimationDidStopWithDriverId:driverId
                                   animationId:groupId
                                      finished:YES];
  XCTAssertFalse(target.flightCovered);

  // Fly home with no `from`: the run starts on the target, where the flight
  // landed, not at the rest the host was put back at.
  groupId = smoothclip::animateTimingGroup(
      7207, {GroupEntry(driverId, false, rest, rest)}, kFlightTiming);
  XCTAssertGreaterThan(groupId, 0);
  UIView *carrier = PresentationContainer(host).superview;
  XCTAssertNotEqual(carrier, host);
  // It departs from the target, which hides for the flight.
  XCTAssertTrue(target.flightCovered);
  CALayer *clipLayer = ((UIView *)[host valueForKey:@"clipContainer"]).layer;
  CAAnimationGroup *geometry =
      (CAAnimationGroup *)[clipLayer animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(geometry);
  BOOL sawPosition = NO;
  for (CAPropertyAnimation *animation in geometry.animations) {
    if (![animation.keyPath isEqualToString:@"position"]) continue;
    sawPosition = YES;
    const CGPoint from =
        [((CABasicAnimation *)animation).fromValue CGPointValue];
    XCTAssertEqualWithAccuracy(from.x, -20 + 200, 1e-9);
    XCTAssertEqualWithAccuracy(from.y, -300 + 250, 1e-9);
  }
  XCTAssertTrue(sawPosition);

  // A departing flight returns into the host and reveals the target.
  [host smoothClipAnimationDidStopWithDriverId:driverId
                                   animationId:groupId
                                      finished:YES];
  XCTAssertEqual(PresentationContainer(host).superview, host);
  XCTAssertFalse(target.flightCovered);
  const smoothclip::Presentation home = smoothclip::snapshotCurrent(driverId);
  XCTAssertEqualWithAccuracy(home.clip.width, rest.clip.width, 1e-9);

  // Without its target on screen there is no way back: a run starts where
  // the host is.
  [target removeFromSuperview];
  XCTAssertNil([[SmoothClipFlightCoordinator shared]
      attachedTargetForTag:@"flight-b"]);
  smoothclip::destroyDriver(driverId);
}

- (void)testTargetThatIsNotReadyHoldsTheLanding {
  constexpr uint64_t driverId = 99205;
  UIWindow *window = TestWindow();
  const smoothclip::Presentation rest = Presentation(0, 0, 160, 120, 16);
  SmoothClipView *host = FlightHost(
      window, CGRectMake(20, 300, 160, 120), driverId, "flight-c", rest);
  const smoothclip::Presentation landing =
      Presentation(-20, -300, 400, 500, 0, -20, -300);
  const int32_t groupId = smoothclip::animateTimingGroup(
      7208, {GroupEntry(driverId, false, rest, landing)}, kFlightTiming);
  SmoothClipFlightTargetView *target =
      FlightTarget(window, CGRectMake(0, 0, 400, 500), "flight-c", false);
  UIView *presentation = PresentationContainer(host);
  UIView *carrier = presentation.superview;

  [host smoothClipAnimationDidStopWithDriverId:driverId
                                   animationId:groupId
                                      finished:YES];
  DrainMainQueue();
  // The flight keeps its last frame in the layer; the target stays hidden.
  XCTAssertEqual(presentation.superview, carrier);
  XCTAssertNotNil(carrier.superview);
  XCTAssertTrue(target.flightCovered);

  SetFlightTargetProps(target, "flight-c", true);
  XCTAssertFalse(target.flightCovered);
  XCTAssertEqual(presentation.superview, host);
  XCTAssertNil(carrier.superview);
  const smoothclip::Presentation settled = smoothclip::snapshotCurrent(driverId);
  XCTAssertEqualWithAccuracy(settled.clip.width, rest.clip.width, 1e-9);
  smoothclip::destroyDriver(driverId);
}

- (void)testTargetRegisteredWhileAirborneIsCovered {
  constexpr uint64_t driverId = 99206;
  UIWindow *window = TestWindow();
  const smoothclip::Presentation rest = Presentation(0, 0, 160, 120, 16);
  SmoothClipView *host = FlightHost(
      window, CGRectMake(20, 300, 160, 120), driverId, "flight-d", rest);
  // A target off screen (an unattached route) is not where the flight
  // departs from: the flight lands on it.
  SmoothClipFlightTargetView *early =
      FlightTarget(nil, CGRectMake(0, 0, 400, 500), "flight-d");
  const int32_t groupId = smoothclip::animateTimingGroup(
      7209,
      {GroupEntry(driverId, false, rest, Presentation(0, 0, 400, 500, 0))},
      kFlightTiming);
  XCTAssertGreaterThan(groupId, 0);
  XCTAssertTrue(early.flightCovered);
  // Attaching it, or registering one, while airborne keeps it hidden.
  [window addSubview:early];
  XCTAssertTrue(early.flightCovered);
  SmoothClipFlightTargetView *late =
      FlightTarget(window, CGRectMake(0, 0, 400, 500), "flight-d");
  XCTAssertTrue(late.flightCovered);
  XCTAssertTrue(TargetContent(late).hidden);
  // A target under another tag is untouched.
  SmoothClipFlightTargetView *other =
      FlightTarget(window, CGRectMake(0, 0, 400, 500), "flight-other");
  XCTAssertFalse(other.flightCovered);

  [host smoothClipAnimationDidStopWithDriverId:driverId
                                   animationId:groupId
                                      finished:YES];
  XCTAssertFalse(early.flightCovered);
  XCTAssertFalse(late.flightCovered);
  smoothclip::destroyDriver(driverId);
}

- (void)testCancelledRunDoesNotHandOff {
  constexpr uint64_t driverId = 99207;
  UIWindow *window = TestWindow();
  const smoothclip::Presentation rest = Presentation(0, 0, 160, 120, 16);
  SmoothClipView *host = FlightHost(
      window, CGRectMake(20, 300, 160, 120), driverId, "flight-e", rest);
  const smoothclip::Presentation landing =
      Presentation(-20, -300, 400, 500, 0, -20, -300);
  const int32_t groupId = smoothclip::animateTimingGroup(
      7210, {GroupEntry(driverId, false, rest, landing)}, kFlightTiming);
  SmoothClipFlightTargetView *target =
      FlightTarget(window, CGRectMake(0, 0, 400, 500), "flight-e");
  UIView *presentation = PresentationContainer(host);
  XCTAssertTrue(target.flightCovered);

  const std::vector<smoothclip::DriverSnapshot> frozen =
      smoothclip::cancelAnimationGroup(
          groupId, smoothclip::GroupCancelBehavior::Freeze);
  XCTAssertEqual(frozen.size(), 1u);
  DrainMainQueue();
  // It lands in place: back in the host where it stopped, target revealed,
  // no reset to rest and no way back.
  XCTAssertEqual(presentation.superview, host);
  XCTAssertFalse(target.flightCovered);
  const smoothclip::Presentation stopped = smoothclip::snapshotCurrent(driverId);
  XCTAssertEqualWithAccuracy(stopped.clip.x, frozen[0].presentation.clip.x, 1e-9);
  XCTAssertEqualWithAccuracy(
      stopped.clip.width, frozen[0].presentation.clip.width, 1e-9);
  XCTAssertFalse([[host valueForKey:@"flightHasLanded"] boolValue]);
  smoothclip::destroyDriver(driverId);
}

- (void)testReplacingAFlyingRunContinuesTheSameLift {
  constexpr uint64_t driverId = 99208;
  UIWindow *window = TestWindow();
  const smoothclip::Presentation rest = Presentation(0, 0, 160, 120, 16);
  SmoothClipView *host = FlightHost(
      window, CGRectMake(20, 300, 160, 120), driverId, "flight-f", rest);
  int32_t groupId = smoothclip::animateTimingGroup(
      7211,
      {GroupEntry(driverId, false, rest, Presentation(0, 0, 300, 300, 0))},
      kFlightTiming);
  UIView *carrier = PresentationContainer(host).superview;
  // A retarget mid-flight, then an interaction, keep the same carrier.
  groupId = smoothclip::animateTimingGroup(
      7212,
      {GroupEntry(driverId, false, rest, Presentation(0, 0, 320, 320, 0))},
      kFlightTiming);
  XCTAssertGreaterThan(groupId, 0);
  DrainMainQueue();
  XCTAssertEqual(PresentationContainer(host).superview, carrier);
  smoothclip::beginGroupInteraction({driverId});
  DrainMainQueue();
  XCTAssertEqual(PresentationContainer(host).superview, carrier);
  // setFrame during the interaction writes to the lifted container.
  XCTAssertTrue(smoothclip::setPresentationBatch(
      {{driverId, Presentation(5, 5, 200, 200, 0)}}));
  DrainMainQueue();
  XCTAssertEqual(PresentationContainer(host).superview, carrier);
  // The next run continues in the same lift and lands it.
  groupId = smoothclip::animateTimingGroup(
      7213, {GroupEntry(driverId, false, rest, rest)}, kFlightTiming);
  XCTAssertEqual(PresentationContainer(host).superview, carrier);
  [host smoothClipAnimationDidStopWithDriverId:driverId
                                   animationId:groupId
                                      finished:YES];
  XCTAssertEqual(PresentationContainer(host).superview, host);
  XCTAssertNil(carrier.superview);

  // An interaction lifts a host at rest too.
  smoothclip::beginGroupInteraction({driverId});
  XCTAssertNotEqual(PresentationContainer(host).superview, host);
  smoothclip::destroyDriver(driverId);
}

- (void)testHostLossMidFlightLandsWithoutTheHost {
  constexpr uint64_t driverId = 99209;
  UIWindow *window = TestWindow();
  const smoothclip::Presentation rest = Presentation(0, 0, 160, 120, 16);
  SmoothClipView *host = FlightHost(
      window, CGRectMake(20, 300, 160, 120), driverId, "flight-g", rest);
  UIView *child = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 40, 40)];
  [host mountChildComponentView:(UIView<RCTComponentViewProtocol> *)child
                          index:0];
  const int32_t groupId = smoothclip::animateTimingGroup(
      7214,
      {GroupEntry(driverId, false, rest, Presentation(-20, -300, 400, 500, 0))},
      kFlightTiming);
  XCTAssertGreaterThan(groupId, 0);
  SmoothClipFlightTargetView *target =
      FlightTarget(window, CGRectMake(0, 0, 400, 500), "flight-g");
  UIView *presentation = PresentationContainer(host);
  UIView *carrier = presentation.superview;
  XCTAssertTrue(target.flightCovered);

  // The route unmounts: its controller is destroyed mid-flight.
  smoothclip::destroyDriver(driverId);
  DrainMainQueue();
  // The flight flies on without the host, which has fresh containers.
  XCTAssertEqual(presentation.superview, carrier);
  XCTAssertNotNil(carrier.superview);
  XCTAssertNotEqual(PresentationContainer(host), presentation);
  XCTAssertEqual(PresentationContainer(host).superview, host);
  XCTAssertTrue(target.flightCovered);
  CAAnimation *keeper =
      [carrier.layer animationForKey:@"smoothClip.flightKeeper"];
  XCTAssertNotNil(keeper);
  XCTAssertGreaterThan(keeper.duration, 4);
  XCTAssertLessThanOrEqual(keeper.duration, 5);
  // Fabric unmounting a child that left with the flight does not assert.
  [host unmountChildComponentView:(UIView<RCTComponentViewProtocol> *)child
                            index:0];
  XCTAssertNil(child.superview);
  // A new child mounts into the fresh content.
  UIView *next = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 40, 40)];
  [host mountChildComponentView:(UIView<RCTComponentViewProtocol> *)next
                          index:0];
  XCTAssertEqual(next.superview, [host valueForKey:@"contentContainer"]);

  // When the run would have ended, the keeper removes the carrier and
  // reveals the target; it never leaves anything behind.
  [keeper.delegate animationDidStop:keeper finished:YES];
  XCTAssertNil(carrier.superview);
  XCTAssertFalse(target.flightCovered);
  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

- (void)testHostDeallocatedMidFlightLandsWithoutTheHost {
  constexpr uint64_t driverId = 99210;
  UIWindow *window = TestWindow();
  const smoothclip::Presentation rest = Presentation(0, 0, 160, 120, 16);
  SmoothClipFlightTargetView *target = nil;
  UIView *carrier = nil;
  __weak SmoothClipView *weakHost = nil;
  @autoreleasepool {
    SmoothClipView *host = FlightHost(
        window, CGRectMake(20, 300, 160, 120), driverId, "flight-h", rest);
    weakHost = host;
    smoothclip::animateTimingGroup(
        7215,
        {GroupEntry(driverId, false, rest, Presentation(0, 0, 400, 500, 0))},
        kFlightTiming);
    target = FlightTarget(window, CGRectMake(0, 0, 400, 500), "flight-h");
    carrier = PresentationContainer(host).superview;
    // Its screen detaches: a lifted host still displays, so this is no host
    // loss and the run keeps going.
    [host removeFromSuperview];
    XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
    XCTAssertNotNil(carrier.superview);
  }
  // The view is gone (dealloc is the host loss here)...
  XCTAssertNil(weakHost);
  // ...and the flight flies on without it.
  XCTAssertNotNil(carrier.superview);
  XCTAssertTrue(target.flightCovered);
  CAAnimation *keeper =
      [carrier.layer animationForKey:@"smoothClip.flightKeeper"];
  XCTAssertNotNil(keeper);
  [keeper.delegate animationDidStop:keeper finished:NO];
  XCTAssertNil(carrier.superview);
  XCTAssertFalse(target.flightCovered);
  XCTAssertFalse(smoothclip::hasActiveAnimation(driverId));
  smoothclip::destroyDriver(driverId);
}

- (void)testMountedTargetCountsAsArrivingForTheGracePeriod {
  constexpr uint64_t driverId = 99211;
  UIWindow *window = TestWindow();
  const smoothclip::Presentation rest = Presentation(0, 0, 160, 120, 16);
  SmoothClipView *host = FlightHost(
      window, CGRectMake(20, 300, 160, 120), driverId, "flight-i", rest);
  const smoothclip::Presentation landing =
      Presentation(-20, -300, 400, 500, 0, -20, -300);
  int32_t groupId = smoothclip::animateTimingGroup(
      7216, {GroupEntry(driverId, false, rest, landing)}, kFlightTiming);
  // A pushed route's target is mounted, but react-native-screens attaches
  // its screen a message later: the flight waits instead of returning.
  SmoothClipFlightTargetView *arriving =
      FlightTarget(nil, CGRectMake(0, 0, 400, 500), "flight-i");
  UIView *presentation = PresentationContainer(host);
  UIView *carrier = presentation.superview;
  [host smoothClipAnimationDidStopWithDriverId:driverId
                                   animationId:groupId
                                      finished:YES];
  DrainMainQueue();
  XCTAssertEqual(presentation.superview, carrier);
  XCTAssertTrue(arriving.flightCovered);
  [window addSubview:arriving];
  XCTAssertEqual(presentation.superview, host);
  XCTAssertFalse(arriving.flightCovered);
  XCTAssertEqualWithAccuracy(
      smoothclip::snapshotCurrent(driverId).clip.width, rest.clip.width, 1e-9);
  [arriving removeFromSuperview];

  // One that never attaches stops counting after 300 ms. The flight saw its
  // target and has none to land on: it lands as a handoff with nothing to
  // reveal, so the host is back at rest (not left at the destination frame).
  groupId = smoothclip::animateTimingGroup(
      7217, {GroupEntry(driverId, false, rest, landing)}, kFlightTiming);
  carrier = presentation.superview;
  XCTAssertNotEqual(carrier, host);
  [host smoothClipAnimationDidStopWithDriverId:driverId
                                   animationId:groupId
                                      finished:YES];
  DrainMainQueue();
  XCTAssertEqual(presentation.superview, carrier);
  [[NSRunLoop mainRunLoop]
      runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
  XCTAssertEqual(presentation.superview, host);
  XCTAssertNil(carrier.superview);
  XCTAssertFalse(arriving.flightCovered);
  XCTAssertEqualWithAccuracy(
      smoothclip::snapshotCurrent(driverId).clip.width, rest.clip.width,
      1e-9);
  smoothclip::destroyDriver(driverId);
}

- (void)testInteractionOnALandedHostStartsFromTheLandedPresentation {
  constexpr uint64_t driverId = 99212;
  UIWindow *window = TestWindow();
  const smoothclip::Presentation rest = Presentation(0, 0, 160, 120, 16);
  SmoothClipView *host = FlightHost(
      window, CGRectMake(20, 300, 160, 120), driverId, "flight-j", rest);
  const smoothclip::Presentation landing =
      Presentation(-20, -300, 400, 500, 0, -20, -300);
  const int32_t groupId = smoothclip::animateTimingGroup(
      7218, {GroupEntry(driverId, false, rest, landing)}, kFlightTiming);
  SmoothClipFlightTargetView *target =
      FlightTarget(window, CGRectMake(0, 0, 400, 500), "flight-j");
  [host smoothClipAnimationDidStopWithDriverId:driverId
                                   animationId:groupId
                                      finished:YES];
  XCTAssertFalse(target.flightCovered);

  // A drag-to-dismiss on the target's content: the lift hides the target, so
  // the host takes over from where the flight landed, not from its rest.
  const std::vector<smoothclip::DriverSnapshot> began =
      smoothclip::beginGroupInteraction({driverId});
  XCTAssertEqual(began.size(), 1u);
  XCTAssertEqualWithAccuracy(began[0].presentation.clip.x, landing.clip.x, 1e-9);
  XCTAssertEqualWithAccuracy(
      began[0].presentation.clip.width, landing.clip.width, 1e-9);
  XCTAssertTrue(target.flightCovered);
  XCTAssertNotEqual(PresentationContainer(host).superview, host);
  const smoothclip::Presentation shown = [host smoothClipCurrentPresentation];
  XCTAssertEqualWithAccuracy(shown.clip.width, landing.clip.width, 1e-9);
  smoothclip::destroyDriver(driverId);
}

// Finding 2. The detail route drives an interaction on the card's way back
// (it follows its own dismissal) and is popped from JS before any run starts:
// its target unmounts, and nothing is left to start the run that would end
// the interaction. The flight must land with the card at rest. Held, it
// stayed above every screen with the target hidden for good.
- (void)testInteractionWhoseDepartedTargetUnmountsLandsTheHostAtRest {
  constexpr uint64_t driverId = 99213;
  UIWindow *window = TestWindow();
  const smoothclip::Presentation rest = Presentation(0, 0, 160, 120, 16);
  SmoothClipView *host = FlightHost(
      window, CGRectMake(20, 300, 160, 120), driverId, "flight-o", rest);
  const smoothclip::Presentation landing =
      Presentation(-20, -300, 400, 500, 0, -20, -300);
  const int32_t groupId = smoothclip::animateTimingGroup(
      7219, {GroupEntry(driverId, false, rest, landing)}, kFlightTiming);
  XCTAssertGreaterThan(groupId, 0);
  SmoothClipFlightTargetView *target =
      FlightTarget(window, CGRectMake(0, 0, 400, 500), "flight-o");
  [host smoothClipAnimationDidStopWithDriverId:driverId
                                   animationId:groupId
                                      finished:YES];
  XCTAssertFalse(target.flightCovered);

  XCTAssertEqual(smoothclip::beginGroupInteraction({driverId}).size(), 1u);
  UIView *presentation = PresentationContainer(host);
  UIView *carrier = presentation.superview;
  XCTAssertNotEqual(carrier, host);
  XCTAssertTrue(target.flightCovered);
  // The dismissal moves the card part of the way home.
  XCTAssertTrue(smoothclip::setPresentationBatch(
      {{driverId, Presentation(-10, -150, 280, 310, 8)}}));
  // An attach change alone does not end the interaction.
  [target removeFromSuperview];
  XCTAssertEqual(presentation.superview, carrier);

  // Fabric recycles the popped route's target.
  [target prepareForRecycle];
  XCTAssertEqual(presentation.superview, host);
  XCTAssertNil(carrier.superview);
  const smoothclip::Presentation settled = smoothclip::snapshotCurrent(driverId);
  XCTAssertEqualWithAccuracy(settled.clip.x, rest.clip.x, 1e-9);
  XCTAssertEqualWithAccuracy(settled.clip.y, rest.clip.y, 1e-9);
  XCTAssertEqualWithAccuracy(settled.clip.width, rest.clip.width, 1e-9);
  XCTAssertEqualWithAccuracy(settled.clip.height, rest.clip.height, 1e-9);
  smoothclip::destroyDriver(driverId);
}

- (void)testTheWayBackOfAScaledHostStartsWhereItsWindowSpaceFlightLanded {
  constexpr uint64_t driverId = 99213;
  UIWindow *window = TestWindow();
  UIView *scaled = [[UIView alloc] initWithFrame:window.bounds];
  scaled.transform = CGAffineTransformMakeScale(0.9, 0.9);
  [window addSubview:scaled];
  const smoothclip::Presentation rest = Presentation(30, 60, 200, 150, 24);
  SmoothClipView *host = FlightHost(
      scaled, window.bounds, driverId, "flight-k", rest);
  smoothclip::GroupMotionEntry open = GroupEntry(
      driverId, false, rest, Presentation(0, 62, 400, 500, 0));
  open.targetInWindow = true;
  int32_t groupId = smoothclip::animateTimingGroup(7219, {open}, kFlightTiming);
  XCTAssertGreaterThan(groupId, 0);
  SmoothClipFlightTargetView *target =
      FlightTarget(window, CGRectMake(0, 62, 400, 500), "flight-k");
  [host smoothClipAnimationDidStopWithDriverId:driverId
                                   animationId:groupId
                                      finished:YES];
  XCTAssertFalse(target.flightCovered);
  XCTAssertTrue([[host valueForKey:@"flightHasLanded"] boolValue]);

  groupId = smoothclip::animateTimingGroup(
      7220, {GroupEntry(driverId, false, rest, rest)}, kFlightTiming);
  XCTAssertGreaterThan(groupId, 0);
  XCTAssertTrue(target.flightCovered);
  CALayer *clipLayer = ((UIView *)[host valueForKey:@"clipContainer"]).layer;
  CAAnimationGroup *geometry =
      (CAAnimationGroup *)[clipLayer animationForKey:@"smoothClip.geometry"];
  XCTAssertNotNil(geometry);
  BOOL sawBounds = NO;
  for (CAPropertyAnimation *animation in geometry.animations) {
    if (![animation.keyPath isEqualToString:@"bounds"]) continue;
    sawBounds = YES;
    const CGRect from = [((CABasicAnimation *)animation).fromValue CGRectValue];
    XCTAssertEqualWithAccuracy(from.size.width, 400 / 0.9, 1e-6);
    XCTAssertEqualWithAccuracy(from.size.height, 500 / 0.9, 1e-6);
  }
  XCTAssertTrue(sawBounds);
  smoothclip::destroyDriver(driverId);
}

#pragma mark - Flight teardown and waits (final review)

// A landing that waits on its target (`ready` false) has no timer: only a
// change of the target wakes it. A target that leaves the flight's tag must
// wake it too, or the content stays in the flight layer for good.
- (void)testTargetThatLeavesItsTagReleasesTheFlightWaitingOnIt {
  constexpr uint64_t driverId = 99230;
  UIWindow *window = TestWindow();
  const smoothclip::Presentation rest = Presentation(0, 0, 160, 120, 16);
  SmoothClipView *host = FlightHost(
      window, CGRectMake(20, 300, 160, 120), driverId, "flight-r", rest);
  const int32_t groupId = smoothclip::animateTimingGroup(
      7230,
      {GroupEntry(
          driverId, false, rest, Presentation(-20, -300, 400, 500, 0))},
      kFlightTiming);
  XCTAssertGreaterThan(groupId, 0);
  SmoothClipFlightTargetView *target =
      FlightTarget(window, CGRectMake(0, 0, 400, 500), "flight-r", false);
  UIView *presentation = PresentationContainer(host);
  UIView *carrier = presentation.superview;
  [host smoothClipAnimationDidStopWithDriverId:driverId
                                   animationId:groupId
                                      finished:YES];
  DrainMainQueue();
  XCTAssertEqual(presentation.superview, carrier);
  XCTAssertTrue(target.flightCovered);

  // React gives the view another tag: nothing is left to wait for.
  SetFlightTargetProps(target, "flight-r-other", false);
  XCTAssertEqual(presentation.superview, host);
  XCTAssertNil(carrier.superview);
  XCTAssertFalse(target.flightCovered);
  smoothclip::destroyDriver(driverId);
}

// The detail route is popped while the card still flies to it, and nothing
// flies the card home. The flight saw its target and lost it: it must land
// with the host back at rest, as a handoff does. Left where it landed, the
// card would stay at the destination frame over the list for good.
- (void)testLandingFlightThatLostItsTargetRestsTheHost {
  constexpr uint64_t driverId = 99232;
  UIWindow *window = TestWindow();
  const smoothclip::Presentation rest = Presentation(0, 0, 160, 120, 16);
  SmoothClipView *host = FlightHost(
      window, CGRectMake(20, 300, 160, 120), driverId, "flight-lost", rest);
  const smoothclip::Presentation landing =
      Presentation(-20, -300, 400, 500, 0, -20, -300);
  int32_t groupId = smoothclip::animateTimingGroup(
      7232, {GroupEntry(driverId, false, rest, landing)}, kFlightTiming);
  XCTAssertGreaterThan(groupId, 0);
  UIView *presentation = PresentationContainer(host);
  UIView *carrier = presentation.superview;
  // The route mounts mid-flight: its target registers and attaches, covered.
  SmoothClipFlightTargetView *target =
      FlightTarget(window, CGRectMake(0, 0, 400, 500), "flight-lost");
  XCTAssertTrue(target.flightCovered);
  // The route is popped: the target leaves the window and Fabric recycles it.
  [target removeFromSuperview];
  [target prepareForRecycle];
  XCTAssertEqual(presentation.superview, carrier);

  [host smoothClipAnimationDidStopWithDriverId:driverId
                                   animationId:groupId
                                      finished:YES];
  DrainMainQueue();
  XCTAssertEqual(presentation.superview, host);
  XCTAssertNil(carrier.superview);
  smoothclip::Presentation settled = smoothclip::snapshotCurrent(driverId);
  XCTAssertEqualWithAccuracy(settled.clip.x, rest.clip.x, 1e-9);
  XCTAssertEqualWithAccuracy(settled.clip.y, rest.clip.y, 1e-9);
  XCTAssertEqualWithAccuracy(settled.clip.width, rest.clip.width, 1e-9);
  XCTAssertEqualWithAccuracy(settled.clip.height, rest.clip.height, 1e-9);

  // A flight whose target never mounted is not a lost target: it returns
  // where it landed (flight-spec.md, Return).
  groupId = smoothclip::animateTimingGroup(
      7233, {GroupEntry(driverId, false, rest, landing)}, kFlightTiming);
  XCTAssertGreaterThan(groupId, 0);
  XCTAssertNotEqual(presentation.superview, host);
  [host smoothClipAnimationDidStopWithDriverId:driverId
                                   animationId:groupId
                                      finished:YES];
  DrainMainQueue();
  XCTAssertEqual(presentation.superview, host);
  settled = smoothclip::snapshotCurrent(driverId);
  XCTAssertEqualWithAccuracy(settled.clip.width, landing.clip.width, 1e-9);
  smoothclip::destroyDriver(driverId);
}

// A target that deallocates with its tag still set (Fabric drops a view it
// does not recycle) must not leave its tag's list behind.
- (void)testDeallocatedTargetLeavesNoRegistryEntry {
  NSDictionary *targets =
      [[SmoothClipFlightCoordinator shared] valueForKey:@"targets"];
  @autoreleasepool {
    SmoothClipFlightTargetView *target =
        FlightTarget(nil, CGRectMake(0, 0, 10, 10), "flight-gone");
    XCTAssertNotNil(targets[@"flight-gone"]);
    target = nil;
  }
  XCTAssertNil(targets[@"flight-gone"]);
}

static facebook::react::MountingTransaction Transaction(
    facebook::react::ShadowViewMutationList mutations) {
  return facebook::react::MountingTransaction(
      1, 1, std::move(mutations), facebook::react::TransactionTelemetry{});
}

// The content of a flying host stays live. A transaction that only removes
// one of its children is an ordinary update; the snapshot that preserves the
// content is for a host that is deleted mid-flight.
- (void)testOnlyHostLossSnapshotsTheFlyingContent {
  constexpr uint64_t driverId = 99231;
  constexpr facebook::react::Tag hostTag = 4242;
  UIWindow *window = TestWindow();
  const smoothclip::Presentation rest = Presentation(0, 0, 160, 120, 16);
  SmoothClipView *host = FlightHost(
      window, CGRectMake(20, 300, 160, 120), driverId, "", rest);
  host.tag = hostTag;
  UIView *image = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 160, 120)];
  UIView *spinner = [[UIView alloc] initWithFrame:CGRectMake(60, 40, 40, 40)];
  [host mountChildComponentView:(UIView<RCTComponentViewProtocol> *)image
                          index:0];
  [host mountChildComponentView:(UIView<RCTComponentViewProtocol> *)spinner
                          index:1];
  const int32_t groupId = smoothclip::animateTimingGroup(
      7231,
      {GroupEntry(
          driverId, false, rest, Presentation(-20, -300, 400, 500, 0))},
      kFlightTiming);
  XCTAssertGreaterThan(groupId, 0);
  UIView *presentation = PresentationContainer(host);
  UIView *carrier = presentation.superview;
  XCTAssertNotEqual(carrier, host);
  UIView *content = (UIView *)[host valueForKey:@"contentContainer"];
  id<RCTMountingTransactionObserving> observer =
      (id<RCTMountingTransactionObserving>)host;
  facebook::react::ShadowView spinnerShadow{};
  spinnerShadow.tag = hostTag + 2;

  // The spinner unmounts when the image has loaded.
  const auto update = Transaction(
      {facebook::react::ShadowViewMutation::RemoveMutation(
          hostTag, spinnerShadow, 1)});
  [observer mountingTransactionWillMount:update withSurfaceTelemetry:{}];
  [host unmountChildComponentView:(UIView<RCTComponentViewProtocol> *)spinner
                            index:1];
  XCTAssertFalse([[host valueForKey:@"flightSnapshotTaken"] boolValue]);
  XCTAssertEqualObjects(content.subviews, @[ image ]);
  XCTAssertEqual(presentation.superview, carrier);

  // The route unmounts: Fabric removes the child, then deletes the host.
  facebook::react::ShadowView imageShadow{};
  imageShadow.tag = hostTag + 1;
  facebook::react::ShadowView hostShadow{};
  hostShadow.tag = hostTag;
  const auto unmount = Transaction(
      {facebook::react::ShadowViewMutation::RemoveMutation(
           hostTag, imageShadow, 0),
       facebook::react::ShadowViewMutation::DeleteMutation(hostShadow)});
  [observer mountingTransactionWillMount:unmount withSurfaceTelemetry:{}];
  XCTAssertTrue([[host valueForKey:@"flightSnapshotTaken"] boolValue]);
  // The flight left with a keeper; the host has fresh containers.
  XCTAssertEqual(presentation.superview, carrier);
  XCTAssertNotEqual(PresentationContainer(host), presentation);
  CAAnimation *keeper =
      [carrier.layer animationForKey:@"smoothClip.flightKeeper"];
  XCTAssertNotNil(keeper);
  [keeper.delegate animationDidStop:keeper finished:YES];
  XCTAssertNil(carrier.superview);
  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

#pragma mark - Flight completions (flight-spec.md, Landing)

- (void)testCompletionReportsTheRestFrameWhenTheHandoffHappensAtCompletion {
  constexpr uint64_t driverId = 99214;
  UIWindow *window = TestWindow();
  const smoothclip::Presentation rest = Presentation(0, 0, 160, 120, 16);
  SmoothClipView *host = FlightHost(
      window, CGRectMake(20, 300, 160, 120), driverId, "flight-l", rest);
  const smoothclip::Presentation landing =
      Presentation(-20, -300, 400, 500, 0, -20, -300);
  std::vector<smoothclip::DriverSnapshot> completed;
  int completions = 0;
  bool allFinished = true;
  smoothclip::setGroupCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t, int32_t, int32_t, bool finished,
          std::vector<smoothclip::DriverSnapshot> snapshots) {
        allFinished = allFinished && finished;
        completions += 1;
        completed = std::move(snapshots);
      });

  // The run finishes on its own.
  int32_t groupId = smoothclip::animateTimingGroup(
      7221, {GroupEntry(driverId, false, rest, landing)}, kFlightTiming);
  SmoothClipFlightTargetView *target =
      FlightTarget(window, CGRectMake(0, 0, 400, 500), "flight-l");
  [host smoothClipAnimationDidStopWithDriverId:driverId
                                   animationId:groupId
                                      finished:YES];
  XCTAssertEqual(completions, 1);
  XCTAssertFalse(target.flightCovered);
  XCTAssertEqual(completed.size(), 1u);
  XCTAssertEqualWithAccuracy(completed[0].presentation.clip.x, rest.clip.x, 1e-9);
  XCTAssertEqualWithAccuracy(
      completed[0].presentation.clip.width, rest.clip.width, 1e-9);
  XCTAssertEqualWithAccuracy(
      completed[0].presentation.clip.radius, rest.clip.radius, 1e-9);

  // `finish` (cancel to the target) hands off too: the cancel's result and the
  // completion both report the rest frame the host shows.
  [target removeFromSuperview];
  groupId = smoothclip::animateTimingGroup(
      7222, {GroupEntry(driverId, false, rest, landing)}, kFlightTiming);
  XCTAssertGreaterThan(groupId, 0);
  [window addSubview:target];
  XCTAssertTrue(target.flightCovered);
  const std::vector<smoothclip::DriverSnapshot> finished =
      smoothclip::cancelAnimationGroup(
          groupId, smoothclip::GroupCancelBehavior::Finish);
  XCTAssertEqual(completions, 2);
  XCTAssertFalse(target.flightCovered);
  XCTAssertEqual(PresentationContainer(host).superview, host);
  XCTAssertEqual(finished.size(), 1u);
  XCTAssertEqualWithAccuracy(finished[0].presentation.clip.width, rest.clip.width, 1e-9);
  XCTAssertEqual(completed.size(), 1u);
  XCTAssertEqualWithAccuracy(completed[0].presentation.clip.width, rest.clip.width, 1e-9);
  XCTAssertEqualWithAccuracy(completed[0].presentation.clip.y, rest.clip.y, 1e-9);
  XCTAssertTrue(allFinished);

  smoothclip::clearGroupCompletionCallback((__bridge const void *)self);
  smoothclip::destroyDriver(driverId);
}

- (void)testCompletionReportsTheLandedFrameWhileTheHandoffWaits {
  constexpr uint64_t driverId = 99215;
  UIWindow *window = TestWindow();
  const smoothclip::Presentation rest = Presentation(0, 0, 160, 120, 16);
  SmoothClipView *host = FlightHost(
      window, CGRectMake(20, 300, 160, 120), driverId, "flight-m", rest);
  const smoothclip::Presentation landing =
      Presentation(-20, -300, 400, 500, 0, -20, -300);
  std::vector<smoothclip::DriverSnapshot> completed;
  int completions = 0;
  smoothclip::setGroupCompletionCallback(
      (__bridge const void *)self,
      [&](uint64_t, int32_t, int32_t, bool,
          std::vector<smoothclip::DriverSnapshot> snapshots) {
        completions += 1;
        completed = std::move(snapshots);
      });
  const int32_t groupId = smoothclip::animateTimingGroup(
      7223, {GroupEntry(driverId, false, rest, landing)}, kFlightTiming);
  SmoothClipFlightTargetView *target =
      FlightTarget(window, CGRectMake(0, 0, 400, 500), "flight-m", false);
  UIView *carrier = PresentationContainer(host).superview;

  [host smoothClipAnimationDidStopWithDriverId:driverId
                                   animationId:groupId
                                      finished:YES];
  // The target is not ready: the flight holds its last frame, and the
  // completion reports that frame.
  XCTAssertEqual(completions, 1);
  XCTAssertEqual(PresentationContainer(host).superview, carrier);
  XCTAssertEqual(completed.size(), 1u);
  XCTAssertEqualWithAccuracy(completed[0].presentation.clip.x, landing.clip.x, 1e-9);
  XCTAssertEqualWithAccuracy(
      completed[0].presentation.clip.width, landing.clip.width, 1e-9);

  // The handoff, later, resets the host without another completion.
  SetFlightTargetProps(target, "flight-m", true);
  XCTAssertFalse(target.flightCovered);
  XCTAssertEqual(PresentationContainer(host).superview, host);
  XCTAssertEqual(completions, 1);
  const smoothclip::Presentation settled = smoothclip::snapshotCurrent(driverId);
  XCTAssertEqualWithAccuracy(settled.clip.width, rest.clip.width, 1e-9);

  smoothclip::clearGroupCompletionCallback((__bridge const void *)self);
  smoothclip::destroyDriver(driverId);
}

#pragma mark - velocity: 'inherit' (flight-spec.md)

// `{ type: 'spring', velocity: 'inherit' }` as the TurboModule passes it.
static smoothclip::SpringAnimation InheritSpring(
    double stiffness = 300,
    double damping = 30) {
  return {1, stiffness, damping, 0, true, 2};
}

// The initial velocity of every CASpringAnimation the host's run installed,
// on the clip and on the content.
static std::vector<double> InstalledSpringVelocities(SmoothClipView *host) {
  std::vector<double> result;
  for (NSString *name in @[ @"clipContainer", @"contentContainer" ]) {
    CALayer *layer = ((UIView *)[host valueForKey:name]).layer;
    for (NSString *key in layer.animationKeys) {
      CAAnimation *animation = [layer animationForKey:key];
      if (![animation isKindOfClass:CAAnimationGroup.class]) continue;
      for (CAAnimation *child in ((CAAnimationGroup *)animation).animations) {
        if ([child isKindOfClass:CASpringAnimation.class]) {
          result.push_back(((CASpringAnimation *)child).initialVelocity);
        }
      }
    }
  }
  return result;
}

// Every spring the host's run installed starts with one velocity in
// [low, high].
- (void)assertSpringVelocitiesOf:(SmoothClipView *)host
                          within:(double)low
                             and:(double)high {
  const std::vector<double> velocities = InstalledSpringVelocities(host);
  XCTAssertGreaterThan(velocities.size(), 1u);
  for (const double velocity : velocities) {
    XCTAssertGreaterThanOrEqual(velocity, low);
    XCTAssertLessThanOrEqual(velocity, high);
    XCTAssertEqualWithAccuracy(velocity, velocities.front(), 1e-12);
  }
}

- (void)testInheritAfterATimingRunReplacedHalfway {
  constexpr uint64_t driverId = 99301;
  UIWindow *window = TestWindow();
  SmoothClipView *host = DisplayableView(window, CGRectMake(0, 0, 400, 400));
  [host setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation a = Presentation(0, 0, 100, 100, 0);
  const smoothclip::Presentation b = Presentation(200, 0, 100, 100, 0);
  smoothclip::registerView(driverId, host, a);
  // Ease-in-out over 400 ms, 200 ms in: it is halfway, at x = 100, moving at
  // its fastest. At the curve's midpoint dy/dx is 1.5 / 0.87, so the run
  // moves 200 * 1.5 / 0.87 / 0.4 pt/s.
  const smoothclip::TimingAnimation easeInOut{400, 0.42, 0, 0.58, 1, 2};
  XCTAssertGreaterThan(
      smoothclip::animateTimingGroup(
          7301, {GroupEntry(driverId, true, a, b)}, easeInOut),
      0);
  const CFTimeInterval epoch = InstalledBeginTime(host);
  Elapse(0.2);

  // Retarget from where it is to x = 300, 200 pt ahead: the spring covers
  // the remaining distance 1.5 / 0.87 / 0.4 = 4.31 times per second.
  const CFTimeInterval before = CACurrentMediaTime();
  const int32_t groupId = smoothclip::animateSpringGroup(
      7302,
      {GroupEntry(driverId, true, Presentation(100, 0, 100, 100, 0),
                  Presentation(300, 0, 100, 100, 0))},
      InheritSpring());
  const CFTimeInterval after = CACurrentMediaTime();
  XCTAssertGreaterThan(groupId, 0);
    const double low =
      smoothclip::timingRunProgress(easeInOut, after - epoch).velocity;
  const double high =
      smoothclip::timingRunProgress(easeInOut, before - epoch).velocity;
  XCTAssertEqualWithAccuracy(low, 1.5 / 0.87 / 0.4, 0.1);
  XCTAssertEqualWithAccuracy(high, 1.5 / 0.87 / 0.4, 0.1);
  [self assertSpringVelocitiesOf:host
                          within:std::min(low, high) - 1e-3
                             and:std::max(low, high) + 1e-3];

  smoothclip::cancelAnimationGroup(groupId, smoothclip::GroupCancelBehavior::Freeze);
  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

- (void)testInheritAfterASpringRunReplaced {
  constexpr uint64_t driverId = 99302;
  UIWindow *window = TestWindow();
  SmoothClipView *host = DisplayableView(window, CGRectMake(0, 0, 400, 400));
  [host setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation a = Presentation(0, 0, 100, 100, 0);
  const smoothclip::Presentation b = Presentation(200, 0, 100, 100, 0);
  smoothclip::registerView(driverId, host, a);
  // An underdamped spring, 80 ms in, with a velocity of its own.
  smoothclip::SpringAnimation moving{1, 300, 20, 2, false, 2};
  XCTAssertGreaterThan(
      smoothclip::animateSpringGroup(
          7303, {GroupEntry(driverId, true, a, b)}, moving),
      0);
  const CFTimeInterval epoch = InstalledBeginTime(host);
  Elapse(0.08);

  // Retarget to x = 450 from x = 50: 400 pt ahead, while the run moves at
  // 200 * v(t) pt/s.
  const CFTimeInterval before = CACurrentMediaTime();
  const int32_t groupId = smoothclip::animateSpringGroup(
      7304,
      {GroupEntry(driverId, true, Presentation(50, 0, 100, 100, 0),
                  Presentation(450, 0, 100, 100, 0))},
      InheritSpring());
  const CFTimeInterval after = CACurrentMediaTime();
  XCTAssertGreaterThan(groupId, 0);
  const double first =
      smoothclip::springRunProgress(moving, before - epoch).velocity * 200 / 400;
  const double last =
      smoothclip::springRunProgress(moving, after - epoch).velocity * 200 / 400;
  XCTAssertGreaterThan(std::min(first, last), 0.5);
  [self assertSpringVelocitiesOf:host
                          within:std::min(first, last) - 1e-3
                             and:std::max(first, last) + 1e-3];

  smoothclip::cancelAnimationGroup(groupId, smoothclip::GroupCancelBehavior::Freeze);
  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

- (void)testInheritAfterAnInteraction {
  constexpr uint64_t driverId = 99303;
  UIWindow *window = TestWindow();
  SmoothClipView *host = DisplayableView(window, CGRectMake(0, 0, 400, 400));
  [host setValue:@(driverId) forKey:@"driverId"];
  smoothclip::registerView(driverId, host, Presentation(0, 0, 100, 100, 0));
  XCTAssertEqual(smoothclip::beginGroupInteraction({driverId}).size(), 1u);

  // Two drag frames 10 pt apart, then a release toward x = 110, 100 pt on.
  const CFTimeInterval firstBefore = CACurrentMediaTime();
  XCTAssertTrue(smoothclip::setPresentationBatch(
      {{driverId, Presentation(0, 0, 100, 100, 0)}}));
  const CFTimeInterval firstAfter = CACurrentMediaTime();
  usleep(12000);
  const CFTimeInterval secondBefore = CACurrentMediaTime();
  XCTAssertTrue(smoothclip::setPresentationBatch(
      {{driverId, Presentation(10, 0, 100, 100, 0)}}));
  const CFTimeInterval secondAfter = CACurrentMediaTime();
  const int32_t groupId = smoothclip::animateSpringGroup(
      7305,
      {GroupEntry(driverId, false, {}, Presentation(110, 0, 100, 100, 0))},
      InheritSpring());
  XCTAssertGreaterThan(groupId, 0);
  // 10 pt over the time between the two writes, per 100 pt left.
  const double low = 10 / (secondAfter - firstBefore) / 100;
  const double high = 10 / (secondBefore - firstAfter) / 100;
  XCTAssertGreaterThan(low, 1);
  [self assertSpringVelocitiesOf:host
                          within:low - 1e-6
                             and:high + 1e-6];

  smoothclip::cancelAnimationGroup(groupId, smoothclip::GroupCancelBehavior::Freeze);
  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

- (void)testInheritResolvesPerDriverAndIsZeroAtRest {
  constexpr uint64_t movingId = 99304;
  constexpr uint64_t restingId = 99305;
  UIWindow *window = TestWindow();
  SmoothClipView *moving = DisplayableView(window, CGRectMake(0, 0, 400, 400));
  SmoothClipView *resting = DisplayableView(window, CGRectMake(0, 0, 400, 400));
  [moving setValue:@(movingId) forKey:@"driverId"];
  [resting setValue:@(restingId) forKey:@"driverId"];
  const smoothclip::Presentation a = Presentation(0, 0, 100, 100, 0);
  smoothclip::registerView(movingId, moving, a);
  smoothclip::registerView(restingId, resting, a);
  // One driver moves at a constant 1000 pt/s (linear, 2000 pt in 2 s,
  // 100 ms in); the other has never moved.
  const smoothclip::TimingAnimation linear{2000, 0, 0, 1, 1, 2};
  XCTAssertGreaterThan(
      smoothclip::animateTimingGroup(
          7306, {GroupEntry(movingId, true, a, Presentation(2000, 0, 100, 100, 0))},
          linear),
      0);
  Elapse(0.1);

  const int32_t groupId = smoothclip::animateSpringGroup(
      7307,
      {
          GroupEntry(movingId, true, Presentation(100, 0, 100, 100, 0),
                     Presentation(300, 0, 100, 100, 0)),
          GroupEntry(restingId, false, {}, Presentation(0, 200, 100, 100, 0)),
      },
      InheritSpring());
  XCTAssertGreaterThan(groupId, 0);
  // 1000 pt/s over 200 pt left: 5 per second. At rest: 0.
  [self assertSpringVelocitiesOf:moving
                          within:5 - 1e-3
                             and:5 + 1e-3];
  [self assertSpringVelocitiesOf:resting
                          within:0
                             and:0];

  smoothclip::cancelAnimationGroup(groupId, smoothclip::GroupCancelBehavior::Freeze);
  for (SmoothClipView *view in @[ moving, resting ]) {
    const uint64_t driverId = [[view valueForKey:@"driverId"] unsignedLongLongValue];
    smoothclip::unregisterView(driverId, view);
    [view setValue:@0 forKey:@"driverId"];
    smoothclip::destroyDriver(driverId);
  }
}

- (void)testInheritedVelocityMustKeepTheContentScalePositive {
  constexpr uint64_t driverId = 99306;
  UIWindow *window = TestWindow();
  SmoothClipView *host = DisplayableView(window, CGRectMake(0, 0, 400, 400));
  [host setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation a = Presentation(0, 0, 100, 100, 0);
  smoothclip::registerView(driverId, host, a);
  // 5000 pt/s (10000 pt in 2 s, linear), retargeted 100 pt ahead while the
  // content shrinks to 0.3: an inherited 50 per second overshoots the target
  // by almost its whole distance, and the scale would cross zero. From rest
  // the same spring overshoots by about a tenth.
  const smoothclip::TimingAnimation linear{2000, 0, 0, 1, 1, 2};
  const int32_t runId = smoothclip::animateTimingGroup(
      7308, {GroupEntry(driverId, true, a, Presentation(10000, 0, 100, 100, 0))},
      linear);
  XCTAssertGreaterThan(runId, 0);
  Elapse(0.1);
  smoothclip::Presentation shrink = Presentation(600, 0, 100, 100, 0);
  shrink.contentScale = 0.3;
  const smoothclip::GroupMotionEntry retarget =
      GroupEntry(driverId, true, Presentation(500, 0, 100, 100, 0), shrink);
  XCTAssertEqual(
      smoothclip::animateSpringGroup(7309, {retarget}, InheritSpring(300, 20)), 0);
  // Rejected atomically: the run keeps going.
  XCTAssertTrue(smoothclip::hasActiveAnimation(driverId));
  // The same spring from rest is fine.
  smoothclip::SpringAnimation still = InheritSpring(300, 20);
  still.inheritVelocity = false;
  const int32_t groupId = smoothclip::animateSpringGroup(7310, {retarget}, still);
  XCTAssertGreaterThan(groupId, 0);

  smoothclip::cancelAnimationGroup(groupId, smoothclip::GroupCancelBehavior::Freeze);
  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

- (void)testInheritOnTheWayBackStartsStillFromTheLandedPresentation {
  constexpr uint64_t driverId = 99307;
  UIWindow *window = TestWindow();
  const smoothclip::Presentation rest = Presentation(0, 0, 160, 120, 16);
  SmoothClipView *host = FlightHost(
      window, CGRectMake(20, 300, 160, 120), driverId, "flight-n", rest);
  const smoothclip::Presentation landing =
      Presentation(-20, -300, 400, 500, 0, -20, -300);
  // Interactive writes just before the flight leave fresh samples behind.
  smoothclip::setPresentation(driverId, Presentation(-10, 0, 160, 120, 16), true);
  usleep(12000);
  smoothclip::setPresentation(driverId, rest, true);
  int32_t groupId = smoothclip::animateTimingGroup(
      7311, {GroupEntry(driverId, false, rest, landing)}, kFlightTiming);
  SmoothClipFlightTargetView *target =
      FlightTarget(window, CGRectMake(0, 0, 400, 500), "flight-n");
  [host smoothClipAnimationDidStopWithDriverId:driverId
                                   animationId:groupId
                                      finished:YES];
  XCTAssertFalse(target.flightCovered);

  groupId = smoothclip::animateSpringGroup(
      7312, {GroupEntry(driverId, false, {}, rest)}, InheritSpring());
  XCTAssertGreaterThan(groupId, 0);
  XCTAssertTrue(target.flightCovered);
  [self assertSpringVelocitiesOf:host
                          within:0
                             and:0];
  CALayer *clipLayer = ((UIView *)[host valueForKey:@"clipContainer"]).layer;
  CAAnimationGroup *geometry =
      (CAAnimationGroup *)[clipLayer animationForKey:@"smoothClip.geometry"];
  // A spring animates the bounds per component.
  BOOL sawWidth = NO;
  for (CAPropertyAnimation *animation in geometry.animations) {
    if (![animation.keyPath isEqualToString:@"bounds.size.width"]) continue;
    sawWidth = YES;
    XCTAssertEqualWithAccuracy(
        [((CABasicAnimation *)animation).fromValue doubleValue],
        landing.clip.width, 1e-9);
  }
  XCTAssertTrue(sawWidth);
  smoothclip::destroyDriver(driverId);
}

#pragma mark - Replacing a moving run (flight-spec.md)

// What the host's installed run animates from, read off its animations' from
// values: the clip rect and corner radius, the content translation and scale.
struct InstalledStart {
  CGRect clip = CGRectNull;
  double radius = NAN;
  double translateX = NAN;
  double translateY = NAN;
  double scale = 1;
};

static InstalledStart InstalledRunStart(SmoothClipView *host) {
  InstalledStart result;
  CALayer *clipLayer = ((UIView *)[host valueForKey:@"clipContainer"]).layer;
  CAAnimationGroup *geometry =
      (CAAnimationGroup *)[clipLayer animationForKey:@"smoothClip.geometry"];
  CGRect rect = CGRectZero;
  BOOL sawRect = NO;
  for (CAPropertyAnimation *child in geometry.animations) {
    id from = ((CABasicAnimation *)child).fromValue;
    NSString *keyPath = child.keyPath;
    if ([keyPath isEqualToString:@"bounds"]) {
      rect = [from CGRectValue];
      sawRect = YES;
    } else if ([keyPath isEqualToString:@"bounds.origin.x"]) {
      rect.origin.x = [from doubleValue];
      sawRect = YES;
    } else if ([keyPath isEqualToString:@"bounds.origin.y"]) {
      rect.origin.y = [from doubleValue];
    } else if ([keyPath isEqualToString:@"bounds.size.width"]) {
      rect.size.width = [from doubleValue];
    } else if ([keyPath isEqualToString:@"bounds.size.height"]) {
      rect.size.height = [from doubleValue];
    } else if ([keyPath isEqualToString:@"cornerRadius"]) {
      result.radius = [from doubleValue];
    }
  }
  if (sawRect) result.clip = rect;
  CALayer *contentLayer =
      ((UIView *)[host valueForKey:@"contentContainer"]).layer;
  CAAnimationGroup *content =
      (CAAnimationGroup *)[contentLayer animationForKey:@"smoothClip.content"];
  for (CAPropertyAnimation *child in content.animations) {
    const double from = [((CABasicAnimation *)child).fromValue doubleValue];
    if ([child.keyPath isEqualToString:@"transform.translation.x"]) {
      result.translateX = from;
    } else if ([child.keyPath isEqualToString:@"transform.translation.y"]) {
      result.translateY = from;
    } else if ([child.keyPath isEqualToString:@"transform.scale"]) {
      result.scale = from;
    }
  }
  return result;
}

- (void)assertRunOf:(SmoothClipView *)host
           startsAt:(const smoothclip::Presentation &)expected {
  const InstalledStart start = InstalledRunStart(host);
  XCTAssertFalse(CGRectIsNull(start.clip));
  XCTAssertEqualWithAccuracy(start.clip.origin.x, expected.clip.x, 1e-9);
  XCTAssertEqualWithAccuracy(start.clip.origin.y, expected.clip.y, 1e-9);
  XCTAssertEqualWithAccuracy(start.clip.size.width, expected.clip.width, 1e-9);
  XCTAssertEqualWithAccuracy(start.clip.size.height, expected.clip.height, 1e-9);
  XCTAssertEqualWithAccuracy(start.radius, expected.clip.radius, 1e-9);
  XCTAssertEqualWithAccuracy(start.translateX, expected.contentTranslateX, 1e-9);
  XCTAssertEqualWithAccuracy(start.translateY, expected.contentTranslateY, 1e-9);
  XCTAssertEqualWithAccuracy(start.scale, expected.contentScale, 1e-9);
}

static smoothclip::Presentation Canonical(smoothclip::Presentation value) {
  smoothclip::canonicalizePresentation(value);
  return value;
}

// The default (flight-spec.md, "Replacing a moving run"): a worklet retargets
// a timing run mid-flight. The new run begins at the call, from its start
// (the explicit `from` here), and inherits the old run's velocity at the
// call.
- (void)testReplacementOfAMovingRunBeginsAtTheCall {
  constexpr uint64_t driverId = 99408;
  UIWindow *window = TestWindow();
  SmoothClipView *host = DisplayableView(window, CGRectMake(0, 0, 400, 400));
  [host setValue:@(driverId) forKey:@"driverId"];
  const smoothclip::Presentation a = Canonical(Presentation(0, 0, 100, 100, 0));
  const smoothclip::Presentation b =
      Canonical(Presentation(200, 0, 100, 100, 0));
  smoothclip::registerView(driverId, host, a);
  // Ease-in-out over 400 ms, 150 ms in: still accelerating.
  const smoothclip::TimingAnimation easeInOut{400, 0.42, 0, 0.58, 1, 2};
  XCTAssertGreaterThan(
      smoothclip::animateTimingGroup(
          7413, {GroupEntry(driverId, true, a, b)}, easeInOut),
      0);
  const CFTimeInterval epoch = InstalledBeginTime(host);
  Elapse(0.15);

  const smoothclip::Presentation from =
      Canonical(Presentation(60, 0, 100, 100, 0));
  const smoothclip::Presentation target =
      Canonical(Presentation(300, 0, 100, 100, 0));
  const CFTimeInterval before = CACurrentMediaTime();
  const int32_t groupId = smoothclip::animateSpringGroup(
      7414, {GroupEntry(driverId, true, from, target)}, InheritSpring());
  const CFTimeInterval after = CACurrentMediaTime();
  XCTAssertGreaterThan(groupId, 0);
  const CFTimeInterval begin = InstalledBeginTime(host);
  XCTAssertGreaterThanOrEqual(begin, before);
  XCTAssertLessThanOrEqual(begin, after);
  [self assertRunOf:host startsAt:from];
  const auto velocityAt = [&](CFTimeInterval time) {
    return smoothclip::inheritedRunVelocityFrom(
        a, b, smoothclip::timingRunProgress(easeInOut, time - epoch), from,
        target);
  };
  const double low = std::min(velocityAt(before), velocityAt(after));
  const double high = std::max(velocityAt(before), velocityAt(after));
  XCTAssertGreaterThan(low, 1);
  [self assertSpringVelocitiesOf:host within:low - 1e-9 and:high + 1e-9];

  smoothclip::cancelAnimationGroup(groupId, smoothclip::GroupCancelBehavior::Freeze);
  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
}

// A call that replaces a moving run and starts a fresh one shares one
// epoch: every run in it begins at its install.
- (void)testAGroupThatReplacesAMovingRunBeginsAsOne {
  constexpr uint64_t movingId = 99409;
  constexpr uint64_t freshId = 99410;
  UIWindow *window = TestWindow();
  SmoothClipView *moving = DisplayableView(window, CGRectMake(0, 0, 400, 400));
  [moving setValue:@(movingId) forKey:@"driverId"];
  SmoothClipView *fresh = DisplayableView(window, CGRectMake(0, 400, 400, 400));
  [fresh setValue:@(freshId) forKey:@"driverId"];
  const smoothclip::Presentation a = Presentation(0, 0, 100, 100, 0);
  const smoothclip::Presentation b = Presentation(200, 0, 100, 100, 0);
  smoothclip::registerView(movingId, moving, a);
  smoothclip::registerView(freshId, fresh, a);
  const smoothclip::TimingAnimation linear{400, 0, 0, 1, 1, 2};

  XCTAssertGreaterThan(
      smoothclip::animateTimingGroup(
          7416, {GroupEntry(movingId, true, a, b)}, linear),
      0);
  Elapse(0.05);
  const CFTimeInterval before = CACurrentMediaTime();
  const int32_t groupId = smoothclip::animateTimingGroup(
      7417,
      {
          GroupEntry(movingId, false, {}, Presentation(0, 200, 100, 100, 0)),
          GroupEntry(freshId, true, a, b),
      },
      linear);
  const CFTimeInterval after = CACurrentMediaTime();
  XCTAssertGreaterThan(groupId, 0);
  const CFTimeInterval begin = InstalledBeginTime(moving);
  XCTAssertGreaterThanOrEqual(begin, before);
  XCTAssertLessThanOrEqual(begin, after);
  XCTAssertEqualWithAccuracy(InstalledBeginTime(fresh), begin, 1e-9);

  smoothclip::cancelAnimationGroup(groupId, smoothclip::GroupCancelBehavior::Freeze);
  for (SmoothClipView *view in @[ moving, fresh ]) {
    const uint64_t driverId = [[view valueForKey:@"driverId"] unsignedLongLongValue];
    smoothclip::unregisterView(driverId, view);
    [view setValue:@0 forKey:@"driverId"];
    smoothclip::destroyDriver(driverId);
  }
}

// A flying host retargeted mid-flight begins the new run at the call, stays
// in its lift, inherits the flight's motion, and lands as before.
- (void)testRetargetOfAFlightBeginsAtTheCallAndContinuesTheLift {
  constexpr uint64_t driverId = 99411;
  UIWindow *window = TestWindow();
  const smoothclip::Presentation rest =
      Canonical(Presentation(0, 0, 160, 120, 16));
  SmoothClipView *host = FlightHost(
      window, CGRectMake(20, 300, 160, 120), driverId, "flight-c", rest);
  const smoothclip::Presentation predicted =
      Canonical(Presentation(-20, -300, 400, 460, 16));
  XCTAssertGreaterThan(
      smoothclip::animateTimingGroup(
          7418, {GroupEntry(driverId, false, {}, predicted)}, kFlightTiming),
      0);
  Elapse(0.2);
  UIView *carrier = PresentationContainer(host).superview;
  XCTAssertNotEqual(carrier, host);

  const smoothclip::Presentation landing =
      Canonical(Presentation(-20, -300, 400, 500, 16));
  const CFTimeInterval before = CACurrentMediaTime();
  const int32_t groupId = smoothclip::animateSpringGroup(
      7419, {GroupEntry(driverId, false, {}, landing)}, InheritSpring());
  const CFTimeInterval after = CACurrentMediaTime();
  XCTAssertGreaterThan(groupId, 0);
  const CFTimeInterval begin = InstalledBeginTime(host);
  XCTAssertGreaterThanOrEqual(begin, before);
  XCTAssertLessThanOrEqual(begin, after);
  DrainMainQueue();
  XCTAssertEqual(PresentationContainer(host).superview, carrier);
  const std::vector<double> velocities = InstalledSpringVelocities(host);
  XCTAssertGreaterThan(velocities.size(), 1u);
  XCTAssertGreaterThan(velocities.front(), 0);

  [host smoothClipAnimationDidStopWithDriverId:driverId
                                   animationId:groupId
                                      finished:YES];
  XCTAssertEqual(PresentationContainer(host).superview, host);
  XCTAssertNil(carrier.superview);
  smoothclip::destroyDriver(driverId);
}

#pragma mark - Mid-run reads

// A window on screen: the hosts' layers reach the render server, so their
// presentation layers carry the installed runs.
static UIWindow *VisibleTestWindow(void) {
  UIWindow *window = TestWindow();
  window.rootViewController = [UIViewController new];
  [window makeKeyAndVisible];
  [CATransaction flush];
  return window;
}

// Lets the render server pick up what was just installed.
static void CommitAndWait(void) {
  [CATransaction flush];
  [[NSRunLoop currentRunLoop]
      runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.03]];
}

// The content channels of a frame `progress` of the way from `from` to `to`,
// as the run draws them (the clip's own progress).
- (void)assertContentOf:(const smoothclip::Presentation &)frame
                   from:(const smoothclip::Presentation &)from
                     to:(const smoothclip::Presentation &)to
             atProgress:(double)progress {
  const auto mix = [progress](double start, double end) {
    return start + (end - start) * progress;
  };
  XCTAssertEqualWithAccuracy(
      frame.contentScale, mix(from.contentScale, to.contentScale), 1e-3);
  XCTAssertEqualWithAccuracy(
      frame.contentTranslateX,
      mix(from.contentTranslateX, to.contentTranslateX), 1e-2);
  XCTAssertEqualWithAccuracy(
      frame.contentTranslateY,
      mix(from.contentTranslateY, to.contentTranslateY), 1e-2);
}

// While a run animates `transform.scale`, a presentation
// layer's `affineTransform` is not the animated matrix, so a mid-run read
// reported the clip where the run was and the content at the run's target.
- (void)testMidRunReadReportsTheVisibleContentOfATimingRun {
  UIWindow *window = VisibleTestWindow();
  SmoothClipView *host = DisplayableView(window, CGRectMake(0, 0, 200, 200));
  auto from = Presentation(20, 40, 100, 60, 8, 10, 20);
  from.contentScale = 0.5;
  [host smoothClipApplyPresentation:from];
  [CATransaction flush];
  const auto target = Presentation(0, 0, 200, 200, 0);
  // Linear over 20 s, begun 8 s ago: about 40 % of the way, however long the
  // run loop takes.
  const smoothclip::TimingAnimation linear{20000, 0, 0, 1, 1, 2};
  XCTAssertTrue([host smoothClipAnimateTiming:target animation:linear
      animationId:22346 sharedBeginTime:CACurrentMediaTime() - 8.0]);
  CommitAndWait();
  const auto visible = [host smoothClipCurrentPresentation];
  const double progress = (visible.clip.width - 100) / 100;
  XCTAssertGreaterThan(progress, 0.35);
  XCTAssertLessThan(progress, 0.5);
  [self assertContentOf:visible from:from to:target atProgress:progress];
  window.hidden = YES;
}

- (void)testMidRunReadReportsTheVisibleContentOfASpringRun {
  UIWindow *window = VisibleTestWindow();
  SmoothClipView *host = DisplayableView(window, CGRectMake(0, 0, 200, 200));
  auto from = Presentation(20, 40, 100, 60, 8, 10, 20);
  from.contentScale = 0.5;
  [host smoothClipApplyPresentation:from];
  [CATransaction flush];
  const auto target = Presentation(0, 0, 200, 200, 0);
  // Critically damped, omega 2/s, begun 1 s ago: about 60 % of the way.
  const smoothclip::SpringAnimation slow{1, 4, 4, 0, false, 2};
  XCTAssertTrue([host smoothClipAnimateSpring:target animation:slow
      animationId:22347 sharedBeginTime:CACurrentMediaTime() - 1.0]);
  CommitAndWait();
  const auto visible = [host smoothClipCurrentPresentation];
  const double progress = (visible.clip.width - 100) / 100;
  XCTAssertGreaterThan(progress, 0.5);
  XCTAssertLessThan(progress, 0.8);
  [self assertContentOf:visible from:from to:target atProgress:progress];
  window.hidden = YES;
}

// The rotation reads the presentation matrix too (`transform`, as the
// content does): mid-run it is the run's angle, not the target's.
- (void)testMidRunReadReportsTheVisibleRotation {
  UIWindow *window = VisibleTestWindow();
  SmoothClipView *host = DisplayableView(window, CGRectMake(0, 0, 200, 200));
  const auto from = Presentation(20, 40, 100, 60, 8);
  [host smoothClipApplyPresentation:from];
  [CATransaction flush];
  auto target = Presentation(0, 0, 200, 200, 0);
  target.rotation = M_PI_2;
  const smoothclip::TimingAnimation linear{20000, 0, 0, 1, 1, 2};
  XCTAssertTrue([host smoothClipAnimateTiming:target animation:linear
      animationId:22348 sharedBeginTime:CACurrentMediaTime() - 8.0]);
  CommitAndWait();
  const auto visible = [host smoothClipCurrentPresentation];
  const double progress = (visible.clip.width - 100) / 100;
  XCTAssertGreaterThan(progress, 0.35);
  XCTAssertEqualWithAccuracy(visible.rotation, M_PI_2 * progress, 1e-3);
  window.hidden = YES;
}

// A baked tile has no shadow offset or spread on the layer; mid-run they
// follow the run, as the tile layer's frame does, not the target's.
- (void)testMidRunReadReportsTheVisibleOffsetOfABakedShadow {
  UIWindow *window = VisibleTestWindow();
  SmoothClipView *host = DisplayableView(window, CGRectMake(0, 0, 400, 400));
  [host setValue:@YES forKey:@"bakedShadows"];
  const smoothclip::Presentation card = PresentationValue(
      20, 250, 360, 100, 20, 20, 20, 20, smoothclip::ClipCurve::Continuous,
      0, 0, 1, BoxShadow(0.25, 0, 2, 16, 0));
  const smoothclip::Presentation full = PresentationValue(
      0, 0, 400, 400, 20, 20, 20, 20, smoothclip::ClipCurve::Continuous,
      0, 0, 1, BoxShadow(0.25, 6, 20, 16, 4));
  [host smoothClipApplyPresentation:card];
  [CATransaction flush];
  CALayer *shadowLayer = [host valueForKey:@"shadowLayer"];
  XCTAssertNotNil(shadowLayer.contents);
  const smoothclip::TimingAnimation linear{20000, 0, 0, 1, 1, 2};
  XCTAssertTrue([host smoothClipAnimateTiming:full animation:linear
      animationId:22349 sharedBeginTime:CACurrentMediaTime() - 8.0]);
  CommitAndWait();
  XCTAssertNotNil(shadowLayer.contents);
  const auto visible = [host smoothClipCurrentPresentation];
  const double progress = (visible.clip.height - 100) / 300;
  XCTAssertGreaterThan(progress, 0.35);
  XCTAssertLessThan(progress, 0.5);
  XCTAssertEqualWithAccuracy(visible.shadow.offsetX, 6 * progress, 1e-2);
  XCTAssertEqualWithAccuracy(visible.shadow.offsetY, 2 + 18 * progress, 1e-2);
  XCTAssertEqualWithAccuracy(visible.shadow.spreadDistance, 4 * progress, 1e-2);
  XCTAssertEqualWithAccuracy(visible.shadow.alpha, 0.25, 1e-6);
  XCTAssertEqualWithAccuracy(visible.shadow.blurRadius, 16, 1e-9);
  window.hidden = YES;
}

// Through the registry: a snapshot and beginInteraction taken
// mid-run report the content where the run is, and the freeze holds it.
- (void)testMidRunSnapshotAndInteractionReportTheVisibleContent {
  constexpr uint64_t driverId = 99501;
  UIWindow *window = VisibleTestWindow();
  SmoothClipView *host = DisplayableView(window, CGRectMake(0, 0, 400, 400));
  [host setValue:@(driverId) forKey:@"driverId"];
  auto card = Presentation(20, 250, 360, 100, 20, -12, 30);
  card.contentScale = 0.6;
  card = Canonical(card);
  const auto detail = Canonical(Presentation(0, 0, 400, 400, 0));
  smoothclip::registerView(driverId, host, card);
  [CATransaction flush];
  // Linear over 1 s, 0.4 s in.
  const smoothclip::TimingAnimation linear{1000, 0, 0, 1, 1, 2};
  XCTAssertGreaterThan(
      smoothclip::animateTimingGroup(
          7501, {GroupEntry(driverId, false, {}, detail)}, linear),
      0);
  Elapse(0.4);
  CommitAndWait();

  const auto snapshot = smoothclip::snapshotGroup({driverId})[0].presentation;
  const double atSnapshot = (snapshot.clip.height - 100) / 300;
  XCTAssertGreaterThan(atSnapshot, 0.3);
  XCTAssertLessThan(atSnapshot, 0.9);
  [self assertContentOf:snapshot from:card to:detail atProgress:atSnapshot];

  const auto frozen =
      smoothclip::beginGroupInteraction({driverId})[0].presentation;
  const double atFreeze = (frozen.clip.height - 100) / 300;
  XCTAssertGreaterThanOrEqual(atFreeze, atSnapshot);
  XCTAssertLessThan(atFreeze, 0.9);
  [self assertContentOf:frozen from:card to:detail atProgress:atFreeze];
  const auto held = [host smoothClipCurrentPresentation];
  XCTAssertEqualWithAccuracy(held.contentScale, frozen.contentScale, 1e-9);
  XCTAssertEqualWithAccuracy(
      held.contentTranslateX, frozen.contentTranslateX, 1e-9);
  XCTAssertEqualWithAccuracy(
      held.contentTranslateY, frozen.contentTranslateY, 1e-9);

  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
  window.hidden = YES;
}

// A jump once recorded on the simulator: a retarget of a moving run starts its content
// channels where the run is at the call, as it does the clip.
- (void)testReplacementOfAMovingRunStartsTheContentWhereItIs {
  constexpr uint64_t driverId = 99502;
  UIWindow *window = VisibleTestWindow();
  SmoothClipView *host = DisplayableView(window, CGRectMake(0, 0, 400, 400));
  [host setValue:@(driverId) forKey:@"driverId"];
  auto card = Presentation(20, 250, 360, 100, 20, -12, 30);
  card.contentScale = 0.6;
  card = Canonical(card);
  const auto predicted = Canonical(Presentation(0, 0, 400, 360, 0));
  const auto detail = Canonical(Presentation(0, 0, 400, 400, 0));
  smoothclip::registerView(driverId, host, card);
  [CATransaction flush];
  const smoothclip::TimingAnimation linear{1500, 0, 0, 1, 1, 2};
  XCTAssertGreaterThan(
      smoothclip::animateTimingGroup(
          7502, {GroupEntry(driverId, false, {}, predicted)}, linear),
      0);
  const CFTimeInterval epoch = InstalledBeginTime(host);
  Elapse(0.3);
  CommitAndWait();

  const CFTimeInterval before = CACurrentMediaTime();
  const int32_t groupId = smoothclip::animateSpringGroup(
      7503, {GroupEntry(driverId, false, {}, detail)}, InheritSpring());
  const CFTimeInterval after = CACurrentMediaTime();
  XCTAssertGreaterThan(groupId, 0);
  const InstalledStart start = InstalledRunStart(host);
  XCTAssertFalse(CGRectIsNull(start.clip));
  // The old run's progress at the call, from the start's clip (the
  // presentation layers' clock may lag the call by a frame).
  const double progress = (start.clip.size.height - 100) / 260;
  XCTAssertGreaterThanOrEqual(progress, (before - epoch) / 1.5 - 0.03);
  XCTAssertLessThanOrEqual(progress, (after - epoch) / 1.5 + 0.03);
  XCTAssertEqualWithAccuracy(start.scale, 0.6 + 0.4 * progress, 1e-3);
  XCTAssertEqualWithAccuracy(start.translateX, -12 * (1 - progress), 1e-2);
  XCTAssertEqualWithAccuracy(start.translateY, 30 * (1 - progress), 1e-2);

  smoothclip::cancelAnimationGroup(
      groupId, smoothclip::GroupCancelBehavior::Freeze);
  smoothclip::unregisterView(driverId, host);
  [host setValue:@0 forKey:@"driverId"];
  smoothclip::destroyDriver(driverId);
  window.hidden = YES;
}

@end
