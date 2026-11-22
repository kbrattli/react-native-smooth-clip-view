#import "SmoothClipView.h"

#import "SmoothClipFlight.h"
#import "SmoothClipFlightTargetView.h"
#import "SmoothClipGeometry.h"
#import "SmoothClipViewRegistry.h"

#include "SmoothClipAnimationCurve.h"
#include "SmoothClipFlightGeometry.h"
#include "SmoothClipVelocityTracker.h"

#import <QuartzCore/QuartzCore.h>
#import <React/RCTConversions.h>
#import <React/RCTFabricComponentsPlugins.h>
#import <React/RCTMountingTransactionObserving.h>
#import <React/RCTUtils.h>
#import <React/UIView+React.h>
#if defined(SMOOTH_CLIP_ENABLE_SIGNPOSTS) && SMOOTH_CLIP_ENABLE_SIGNPOSTS
#import <os/signpost.h>
#endif
#import <react/renderer/components/SmoothClipViewSpec/ComponentDescriptors.h>
#import <react/renderer/components/SmoothClipViewSpec/Props.h>
#import <react/renderer/components/SmoothClipViewSpec/RCTComponentViewHelpers.h>

#include <algorithm>
#include <cfloat>
#include <cmath>

using namespace facebook::react;

#include "SmoothClipHeroTrace.h"

#if SMOOTH_CLIP_HERO_TRACE
#import <objc/runtime.h>

// Bench instrumentation (docs/hero-bench.md): logs the hardware time of every
// touch-up, so a run can be timed from the finger lift, not from a handler.
static void (*SmoothClipHeroTraceOriginalSendEvent)(id, SEL, UIEvent *);
static void SmoothClipHeroTraceSendEvent(id self, SEL _cmd, UIEvent *event) {
  if (event.type == UIEventTypeTouches) {
    for (UITouch *touch in event.allTouches) {
      if (touch.phase == UITouchPhaseEnded) {
        HERO_TRACE("touch-ended at=%.6f", touch.timestamp);
      }
    }
  }
  SmoothClipHeroTraceOriginalSendEvent(self, _cmd, event);
}

@interface SmoothClipHeroTraceTouches : NSObject
@end

@implementation SmoothClipHeroTraceTouches
+ (void)load {
  Method sendEvent = class_getInstanceMethod(UIApplication.class, @selector(sendEvent:));
  SmoothClipHeroTraceOriginalSendEvent =
      (void (*)(id, SEL, UIEvent *))method_setImplementation(
          sendEvent, (IMP)SmoothClipHeroTraceSendEvent);
}
@end
#endif // SMOOTH_CLIP_HERO_TRACE

// The host's stand-in in the window's flight layer while it flies: the host's
// size, drawn through the host's transform to the window, never hit-testable.
@interface SmoothClipFlightCarrierView : UIView
@end

@implementation SmoothClipFlightCarrierView
- (id<CAAction>)actionForLayer:(CALayer *)layer forKey:(NSString *)event {
  return (id<CAAction>)[NSNull null];
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
  return nil;
}
@end

// Lands a flight whose host was deleted mid-run. It keeps the carrier, and the
// containers still flying in it, until the run would have ended; then it
// removes the carrier and reveals the targets. Core Animation retains it as
// the delegate of a no-op animation on the carrier, so anything that removes
// the carrier's animations (backgrounding) lands it too.
@interface SmoothClipFlightKeeper : NSObject <CAAnimationDelegate, SmoothClipFlightHost>
@property (nonatomic, strong) UIView *carrier;
@property (nonatomic, copy) NSString *tag;
@property (nonatomic, assign) BOOL landed;
- (void)landAfter:(CFTimeInterval)remaining;
@end

static NSString *const kSmoothClipFlightKeeperKey = @"smoothClip.flightKeeper";

@implementation SmoothClipFlightKeeper

- (void)smoothClipFlightTargetsDidChange {
}

- (void)landAfter:(CFTimeInterval)remaining {
  if (!(remaining > 0) || self.carrier.window == nil) {
    [self land];
    return;
  }
  CABasicAnimation *keeper = [CABasicAnimation animationWithKeyPath:@"opacity"];
  keeper.fromValue = @1;
  keeper.toValue = @1;
  keeper.duration = remaining;
  keeper.delegate = self;
  [self.carrier.layer addAnimation:keeper forKey:kSmoothClipFlightKeeperKey];
}

- (void)animationDidStop:(CAAnimation *)animation finished:(BOOL)finished {
  [self land];
}

- (void)land {
  if (self.landed) return;
  self.landed = YES;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [self.carrier removeFromSuperview];
  [[SmoothClipFlightCoordinator shared] host:self didLandWithTag:self.tag ?: @""];
  [CATransaction commit];
  self.carrier = nil;
}

@end

typedef NS_ENUM(NSInteger, SmoothClipFlightOutcome) {
  // A run (or an interaction) owns the lifted host.
  SmoothClipFlightOutcomeRunning = 0,
  SmoothClipFlightOutcomeFinished,
  SmoothClipFlightOutcomeCancelled,
};

@class SmoothClipView;

@interface SmoothClipAnimationDelegate : NSObject <CAAnimationDelegate>
@property(nonatomic, weak) SmoothClipView *view;
@property(nonatomic, assign) uint64_t driverId;
@property(nonatomic, assign) int32_t animationId;
// Set when the animation is torn down deliberately. The running CAAnimation
// copies share this delegate object, so this suppresses their didStop even
// when Core Animation delivers it after the teardown returns.
@property(nonatomic, assign) BOOL invalidated;
@end

@interface SmoothClipContainerView : UIView
@end

@implementation SmoothClipContainerView

- (id<CAAction>)actionForLayer:(CALayer *)layer forKey:(NSString *)event {
  // Geometry is always driven explicitly, either by a HostFunction update or
  // by the animations installed below. Avoid a CATransaction on every frame.
  return (id<CAAction>)[NSNull null];
}

// UIKit normally hit-tests the target model tree. During native motion, use
// the visible bounds/transform/opacity instead, including a fade whose target
// opacity is already zero. These containers have no consumer-owned handlers.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
  CALayer *visible = self.layer.animationKeys.count > 0 ? self.layer.presentationLayer : nil;
  return CGRectContainsPoint(visible != nil ? visible.bounds : self.bounds, point);
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
  CALayer *visible = self.layer.animationKeys.count > 0 ? self.layer.presentationLayer : nil;
  if (self.hidden || !self.userInteractionEnabled ||
      (visible != nil ? visible.opacity : self.layer.opacity) <= 0) return nil;
  if (visible != nil && self.layer.animationKeys.count > 0) {
    CGPoint parentPoint = [self.layer convertPoint:point toLayer:self.layer.superlayer];
    point = [visible convertPoint:parentPoint fromLayer:visible.superlayer];
  }
  if (![self pointInside:point withEvent:event]) return nil;
  for (UIView *child in self.subviews.reverseObjectEnumerator) {
    UIView *hit = [child hitTest:[self convertPoint:point toView:child] withEvent:event];
    if (hit != nil) return hit;
  }
  return self;
}

@end

@interface SmoothClipPresentationContainerView : SmoothClipContainerView
@end
@implementation SmoothClipPresentationContainerView
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { return YES; }
@end

@interface SmoothClipView () <RCTSmoothClipViewViewProtocol, RCTMountingTransactionObserving, SmoothClipFlightHost>
- (void)smoothClipAnimationDidStopWithDriverId:(uint64_t)driverId
                                    animationId:(int32_t)animationId
                                       finished:(BOOL)finished;
@end

static SmoothClipCornerRadii SmoothClipPresentationRadii(
    const smoothclip::Geometry &geometry) {
  return {
      (CGFloat)smoothclip::resolvedRadius(
          geometry.topLeftRadius, geometry.radius),
      (CGFloat)smoothclip::resolvedRadius(
          geometry.topRightRadius, geometry.radius),
      (CGFloat)smoothclip::resolvedRadius(
          geometry.bottomRightRadius, geometry.radius),
      (CGFloat)smoothclip::resolvedRadius(
          geometry.bottomLeftRadius, geometry.radius),
  };
}

static BOOL SmoothClipPresentationHasExplicitRadii(
    const smoothclip::Geometry &geometry) {
  return isfinite(geometry.topLeftRadius) ||
      isfinite(geometry.topRightRadius) ||
      isfinite(geometry.bottomRightRadius) ||
      isfinite(geometry.bottomLeftRadius);
}

static SmoothClipCornerCurve SmoothClipPresentationCurve(
    const smoothclip::Geometry &geometry) {
  return geometry.curve == smoothclip::ClipCurve::Continuous
      ? SmoothClipCornerCurveContinuous
      : SmoothClipCornerCurveCircular;
}

static bool SmoothClipBuildPresentation(
    double x,
    double y,
    double width,
    double height,
    double topLeftRadius,
    double topRightRadius,
    double bottomRightRadius,
    double bottomLeftRadius,
    NSInteger curveCode,
    double contentTranslateX,
    double contentTranslateY,
    double contentScale,
    BOOL shadowEnabled,
    double shadowRed,
    double shadowGreen,
    double shadowBlue,
    double shadowAlpha,
    double shadowOffsetX,
    double shadowOffsetY,
    double shadowBlurRadius,
    double shadowSpreadDistance,
    double rotation,
    double opacity,
    double backdropTranslateX,
    double backdropTranslateY,
    smoothclip::Presentation *result) {
  if (result == nullptr || !isfinite(x) || !isfinite(y) ||
      !isfinite(width) || !isfinite(height) ||
      !isfinite(topLeftRadius) || !isfinite(topRightRadius) ||
      !isfinite(bottomRightRadius) || !isfinite(bottomLeftRadius) ||
      !isfinite(contentTranslateX) || !isfinite(contentTranslateY) ||
      !isfinite(contentScale) || !isfinite(shadowRed) ||
      !isfinite(shadowGreen) || !isfinite(shadowBlue) ||
      !isfinite(shadowAlpha) ||
      !isfinite(shadowOffsetX) || !isfinite(shadowOffsetY) ||
      !isfinite(shadowBlurRadius) || !isfinite(shadowSpreadDistance) ||
      !isfinite(rotation) || !isfinite(opacity) ||
      !isfinite(backdropTranslateX) || !isfinite(backdropTranslateY) ||
      contentScale <= 0 || shadowRed < 0 || shadowRed > 1 ||
      shadowGreen < 0 || shadowGreen > 1 ||
      shadowBlue < 0 || shadowBlue > 1 ||
      shadowAlpha < 0 || shadowAlpha > 1 || shadowBlurRadius < 0 ||
      (curveCode != static_cast<NSInteger>(smoothclip::ClipCurve::Circular) &&
       curveCode != static_cast<NSInteger>(smoothclip::ClipCurve::Continuous))) {
    return false;
  }

  const bool uniform = topLeftRadius == topRightRadius &&
      topLeftRadius == bottomRightRadius &&
      topLeftRadius == bottomLeftRadius;
  smoothclip::Geometry geometry{
      x, y, width, height, uniform ? topLeftRadius : 0};
  geometry.topLeftRadius = topLeftRadius;
  geometry.topRightRadius = topRightRadius;
  geometry.bottomRightRadius = bottomRightRadius;
  geometry.bottomLeftRadius = bottomLeftRadius;
  geometry.curve = static_cast<smoothclip::ClipCurve>(curveCode);
  const smoothclip::Shadow shadow{
      shadowEnabled,
      shadowRed,
      shadowGreen,
      shadowBlue,
      shadowAlpha,
      shadowOffsetX,
      shadowOffsetY,
      shadowBlurRadius,
      shadowSpreadDistance};
  *result = {
      geometry, contentTranslateX, contentTranslateY, contentScale, shadow,
      rotation, smoothclip::clamp01(opacity), backdropTranslateX,
      backdropTranslateY};
  return true;
}

static bool SmoothBoxShadowEqual(
    const smoothclip::Shadow &first,
    const smoothclip::Shadow &second) {
  return first.enabled == second.enabled &&
      first.red == second.red && first.green == second.green &&
      first.blue == second.blue && first.alpha == second.alpha &&
      first.offsetX == second.offsetX && first.offsetY == second.offsetY &&
      first.blurRadius == second.blurRadius &&
      first.spreadDistance == second.spreadDistance;
}

static bool SmoothBoxShadowVisible(
    SmoothClipCanonicalGeometry geometry,
    const smoothclip::Shadow &shadow) {
  return shadow.enabled && shadow.alpha > 0 && !CGRectIsEmpty(geometry.rect);
}

static smoothclip::Shadow SmoothBoxShadowWithEffectiveAlpha(
    SmoothClipCanonicalGeometry geometry,
    smoothclip::Shadow shadow) {
  if (!SmoothBoxShadowVisible(geometry, shadow)) {
    shadow.alpha = 0;
  }
  return shadow;
}

static void SmoothBoxShadowNormalizeAnimationEndpoints(
    SmoothClipCanonicalGeometry fromGeometry,
    smoothclip::Shadow *fromShadow,
    SmoothClipCanonicalGeometry toGeometry,
    smoothclip::Shadow *toShadow) {
  const bool fromVisible = SmoothBoxShadowVisible(fromGeometry, *fromShadow);
  const bool toVisible = SmoothBoxShadowVisible(toGeometry, *toShadow);
  if (fromVisible == toVisible) {
    *fromShadow = SmoothBoxShadowWithEffectiveAlpha(
        fromGeometry, *fromShadow);
    *toShadow = SmoothBoxShadowWithEffectiveAlpha(toGeometry, *toShadow);
    return;
  }

  smoothclip::Shadow *invisible = fromVisible ? toShadow : fromShadow;
  const smoothclip::Shadow &visible = fromVisible ? *fromShadow : *toShadow;
  invisible->enabled = true;
  invisible->red = visible.red;
  invisible->green = visible.green;
  invisible->blue = visible.blue;
  invisible->alpha = 0;
  invisible->offsetX = visible.offsetX;
  invisible->offsetY = visible.offsetY;
  invisible->blurRadius = visible.blurRadius;
  invisible->spreadDistance = visible.spreadDistance;
}

static bool SmoothBoxShadowColorEqual(
    const smoothclip::Shadow &first,
    const smoothclip::Shadow &second) {
  return first.red == second.red && first.green == second.green &&
      first.blue == second.blue && first.alpha == second.alpha;
}

static bool SmoothBoxShadowPathInputEqual(
    SmoothClipCanonicalGeometry firstGeometry,
    const smoothclip::Shadow &firstShadow,
    SmoothClipCanonicalGeometry secondGeometry,
    const smoothclip::Shadow &secondShadow) {
  return CGRectEqualToRect(firstGeometry.rect, secondGeometry.rect) &&
      SmoothClipCornerRadiiEqual(
          firstGeometry.radii, secondGeometry.radii) &&
      firstGeometry.curve == secondGeometry.curve &&
      firstShadow.spreadDistance == secondShadow.spreadDistance;
}

static CGFloat SmoothClipAdjustedShadowRadius(
    CGFloat radius,
    CGFloat spread) {
  const CGFloat magnitude = ABS(spread);
  CGFloat multiplier = 1;
  if (magnitude > 0 && radius < magnitude) {
    multiplier = 1 + pow(radius / magnitude - 1, 3);
  }
  return MAX(0, radius + spread * multiplier);
}

static CGPathRef SmoothClipCreateShadowPath(
    SmoothClipCanonicalGeometry geometry,
    const smoothclip::Shadow &shadow) {
  const CGFloat spread = shadow.spreadDistance;
  CGRect rect = CGRectInset(geometry.rect, -spread, -spread);
  if (CGRectGetWidth(rect) <= 0 || CGRectGetHeight(rect) <= 0) {
    rect = CGRectZero;
  }
  const SmoothClipCornerRadii radii = {
      SmoothClipAdjustedShadowRadius(geometry.radii.topLeft, spread),
      SmoothClipAdjustedShadowRadius(geometry.radii.topRight, spread),
      SmoothClipAdjustedShadowRadius(geometry.radii.bottomRight, spread),
      SmoothClipAdjustedShadowRadius(geometry.radii.bottomLeft, spread),
  };
  return SmoothClipCreateRoundedRectPath(rect, radii, geometry.curve);
}

static NSString *SmoothClipCALayerCornerCurve(
    SmoothClipCornerCurve curve) API_AVAILABLE(ios(13.0)) {
  return curve == SmoothClipCornerCurveContinuous
      ? kCACornerCurveContinuous
      : kCACornerCurveCircular;
}

static CGAffineTransform SmoothClipContentTransform(
    CGFloat scale,
    CGPoint translation) {
  // Construct the matrix directly. Concatenating a translation and a scale is
  // order-sensitive and can multiply tx/ty; the presentation contract requires
  // a centered uniform scale with translation remaining in unscaled points.
  return CGAffineTransformMake(
      scale, 0, 0, scale, translation.x, translation.y);
}

struct SmoothClipPathEndpoints {
  CGPoint points[9];
  size_t count;
};

static void SmoothClipCollectPathEndpoints(
    void *context,
    const CGPathElement *element) {
  SmoothClipPathEndpoints *endpoints =
      static_cast<SmoothClipPathEndpoints *>(context);
  if (endpoints->count >= 9 ||
      element->type == kCGPathElementCloseSubpath) {
    return;
  }
  const size_t endpointIndex =
      element->type == kCGPathElementAddCurveToPoint ? 2 :
      element->type == kCGPathElementAddQuadCurveToPoint ? 1 : 0;
  endpoints->points[endpoints->count++] = element->points[endpointIndex];
}

static SmoothClipCornerRadii SmoothClipRadiiFromFixedPath(
    CGPathRef path,
    CGRect rect,
    SmoothClipCornerRadii fallback) {
  if (path == nil) return fallback;
  SmoothClipPathEndpoints endpoints{};
  CGPathApply(path, &endpoints, SmoothClipCollectPathEndpoints);
  if (endpoints.count != 9) return fallback;
  return {
      MAX(0, endpoints.points[0].x - CGRectGetMinX(rect)),
      MAX(0, CGRectGetMaxX(rect) - endpoints.points[1].x),
      MAX(0, CGRectGetMaxY(rect) - endpoints.points[3].y),
      MAX(0, endpoints.points[5].x - CGRectGetMinX(rect)),
  };
}

static std::array<double, 11> SmoothClipVelocityChannels(
    CGRect rect,
    SmoothClipCornerRadii radii,
    CGPoint contentTranslation,
    CGFloat contentScale) {
  return {CGRectGetMinX(rect),
          CGRectGetMinY(rect),
          CGRectGetWidth(rect),
          CGRectGetHeight(rect),
          radii.topLeft,
          radii.topRight,
          radii.bottomRight,
          radii.bottomLeft,
          contentTranslation.x,
          contentTranslation.y,
          contentScale};
}

// Core Animation uses the overdamped physical solution as well as the critical
// and underdamped ones. Read at snapshot time only: the rotation's turn count,
// and a baked shadow's offset and spread (installedRunProgress:).
static double SmoothClipCARotationProgress(double elapsed, const smoothclip::SpringAnimation &spring) {
  const double omega = std::sqrt(spring.stiffness / spring.mass);
  const double zeta = spring.damping / (2 * std::sqrt(spring.stiffness * spring.mass));
  if (zeta <= 1) {
    return smoothclip::advanceScalarSpring({0, spring.initialVelocity}, spring, elapsed).position;
  }
  const double root = std::sqrt(zeta * zeta - 1);
  const double slow = -omega / (zeta + root);
  const double fast = -omega * (zeta + root);
  const double a = (spring.initialVelocity + fast) / (slow - fast);
  return 1 + a * std::exp(slow * elapsed) + (-1 - a) * std::exp(fast * elapsed);
}

static BOOL SmoothClipRotatedRectIntersectsHost(CGRect rect, CGRect host, double rotation) {
  return smoothclip::rotatedRectIntersectsHost(rect.origin.x - host.origin.x,
      rect.origin.y - host.origin.y, rect.size.width, rect.size.height, rotation,
      host.size.width, host.size.height);
}

static smoothclip::Presentation SmoothClipCanonicalSnapshot(
    smoothclip::Presentation presentation) {
  smoothclip::canonicalizePresentation(presentation);
  return presentation;
}

// MARK: - Baked shadow tiles

// A rounded-rect shadow's pixels depend only on corner radius, blur, spread
// and colour, so one square tile holds every distinct pixel such a shadow can
// show: four corners and a band between them that the compositor stretches
// (`contentsCenter`) to any aperture, with no blur per frame. The margin on
// each side of the shape is 3σ (1.5 × the CSS blur radius): it holds the tail
// outside the shape and separates the band from the corners, so a stretched
// edge is a true straight-edge profile.
static const CGFloat kSmoothClipShadowTileBand = 2;
// Tile radii round up to this step, so a drag ramping the radius bakes a
// handful of tiles rather than one per frame, and a tile corner is never
// tighter than the clip corner over it (that would read as a dark sliver).
static const CGFloat kSmoothClipShadowTileRadiusStep = 4;

@interface SmoothClipShadowTile : NSObject
@property(nonatomic, readonly) CGImageRef image;
/** Shape corner radius the tile was baked for, in points. */
@property(nonatomic, readonly) CGFloat radius;
/** Tile border beyond the shape rect on each side, in points. */
@property(nonatomic, readonly) CGFloat margin;
@property(nonatomic, readonly) CGFloat side;
@property(nonatomic, readonly) CGFloat scale;
@property(nonatomic, readonly) CGRect contentsCenter;
@end

@implementation SmoothClipShadowTile
- (instancetype)initWithImage:(CGImageRef)image
                       radius:(CGFloat)radius
                       margin:(CGFloat)margin
                         side:(CGFloat)side
                        scale:(CGFloat)scale {
  if (self = [super init]) {
    _image = CGImageRetain(image);
    _radius = radius;
    _margin = margin;
    _side = side;
    _scale = scale;
    const CGFloat corner = 2 * margin + radius;
    _contentsCenter = CGRectMake(
        corner / side, corner / side,
        kSmoothClipShadowTileBand / side, kSmoothClipShadowTileBand / side);
  }
  return self;
}
- (void)dealloc {
  CGImageRelease(_image);
}
@end

static CGFloat SmoothClipBakedShadowTileRadius(CGFloat radius) {
  return ceil(MAX(0, radius) / kSmoothClipShadowTileRadiusStep) *
      kSmoothClipShadowTileRadiusStep;
}

static CGFloat SmoothClipBakedShadowMargin(const smoothclip::Shadow &shadow) {
  return ceil(1.5 * MAX(0, shadow.blurRadius));
}

// Baked once per (radius step, curve, blur, colour, scale) and cached for the
// process. The tile is the pure blurred shape the compositor draws for a
// `shadowPath` layer, with nothing filled in on top of it; colour alpha is
// applied as layer opacity. It is drawn with a Core Graphics shadow, not by
// rendering a layer: `renderInContext:` draws a layer's shadow only where the
// layer has content of its own, so a shadowPath-only layer renders nothing.
// A Core Graphics shadow of `b` has sigma b / 2, the same sigma Core
// Animation gives `shadowRadius` b / 2 (the blur path's setting), so the two
// tails match sample for sample. The context comes from a UIKit image
// renderer, whose base transform scales the blur with the tile's scale; a
// hand-scaled CGBitmapContext leaves the shadow in pixel space.
static NSCache<NSString *, SmoothClipShadowTile *> *SmoothClipShadowTileCache(void) {
  static NSCache<NSString *, SmoothClipShadowTile *> *cache;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [NSCache new];
    cache.countLimit = 24;
  });
  return cache;
}

static NSString *SmoothClipShadowTileKey(
    CGFloat tileRadius,
    SmoothClipCornerCurve curve,
    const smoothclip::Shadow &shadow,
    CGFloat scale) {
  return [NSString stringWithFormat:@"%g|%d|%g|%g|%g|%g|%g",
      tileRadius, (int)curve, MAX(0, shadow.blurRadius),
      smoothclip::clamp01(shadow.red), smoothclip::clamp01(shadow.green),
      smoothclip::clamp01(shadow.blue), scale];
}

// The cached tile for this radius step, or nil. Never bakes.
static SmoothClipShadowTile *SmoothClipCachedShadowTile(
    CGFloat tileRadius,
    SmoothClipCornerCurve curve,
    const smoothclip::Shadow &shadow,
    CGFloat scale) {
  return [SmoothClipShadowTileCache()
      objectForKey:SmoothClipShadowTileKey(tileRadius, curve, shadow, scale)];
}

// Radius steps searched on either side of a missing tile for one to show
// while it bakes.
static const int kSmoothClipShadowTileSearchSteps = 16;

// The cached tile nearest to `tileRadius`: the exact one, else at each
// distance the rounder neighbour before the tighter one (a tile corner
// tighter than the clip corner over it reads as a dark sliver; a rounder one
// only recedes under the clip). Never bakes.
static SmoothClipShadowTile *SmoothClipNearestCachedShadowTile(
    CGFloat tileRadius,
    SmoothClipCornerCurve curve,
    const smoothclip::Shadow &shadow,
    CGFloat scale) {
  for (int distance = 0; distance <= kSmoothClipShadowTileSearchSteps;
       distance += 1) {
    const CGFloat delta = distance * kSmoothClipShadowTileRadiusStep;
    SmoothClipShadowTile *tile =
        SmoothClipCachedShadowTile(tileRadius + delta, curve, shadow, scale);
    if (tile != nil) return tile;
    if (distance == 0 || tileRadius - delta < 0) continue;
    tile = SmoothClipCachedShadowTile(tileRadius - delta, curve, shadow, scale);
    if (tile != nil) return tile;
  }
  return nil;
}

// Bakes on the calling thread and caches the result: about a millisecond for
// a 16 pt blur at 3x, growing with blur² × scale². The callers reach for it
// only when nothing else can be shown (a cold cache, at mount) and for a
// run's resting target, which must be exact from the run's last frame on;
// every other tile bakes through SmoothClipRequestShadowTile, off the frame.
static NSUInteger gSmoothClipShadowTileBakeCount = 0;
static SmoothClipShadowTile *SmoothClipBakeShadowTile(
    CGFloat tileRadius,
    SmoothClipCornerCurve curve,
    const smoothclip::Shadow &shadow,
    CGFloat scale) {
  NSString *key = SmoothClipShadowTileKey(tileRadius, curve, shadow, scale);
  SmoothClipShadowTile *tile = [SmoothClipShadowTileCache() objectForKey:key];
  if (tile != nil) return tile;
  gSmoothClipShadowTileBakeCount += 1;
  const CGFloat margin = SmoothClipBakedShadowMargin(shadow);

  const CGFloat side = 2 * (2 * margin + tileRadius) + kSmoothClipShadowTileBand;
  const CGRect shape = CGRectInset(CGRectMake(0, 0, side, side), margin, margin);
  const SmoothClipCornerRadii radii = {
      tileRadius, tileRadius, tileRadius, tileRadius};
  CGPathRef path = SmoothClipCreateRoundedRectPath(shape, radii, curve);
  CGColorRef color = [UIColor colorWithRed:smoothclip::clamp01(shadow.red)
                                     green:smoothclip::clamp01(shadow.green)
                                      blue:smoothclip::clamp01(shadow.blue)
                                     alpha:1].CGColor;
  const CGFloat blur = MAX(0, shadow.blurRadius);
  UIGraphicsImageRendererFormat *format =
      [UIGraphicsImageRendererFormat defaultFormat];
  format.scale = scale;
  format.opaque = NO;
  format.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
  UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
      initWithSize:CGSizeMake(side, side) format:format];
  UIImage *rendered = [renderer imageWithActions:^(
      UIGraphicsImageRendererContext *rendererContext) {
    CGContextRef context = rendererContext.CGContext;
    // Only the shadow lands on the tile: the shape itself is filled far
    // outside the bitmap and its shadow offset back by the same distance,
    // so the interior keeps the blurred shape's own profile (0.5 at the
    // edge) instead of a hard fill.
    const CGFloat away = 4 * side;
    CGContextSetShadowWithColor(context, CGSizeMake(0, -away), blur, color);
    CGContextTranslateCTM(context, 0, away);
    CGContextAddPath(context, path);
    CGContextSetFillColorWithColor(context, color);
    CGContextFillPath(context);
  }];
  CGPathRelease(path);
  CGImageRef image = rendered.CGImage;
  if (image == NULL) return nil;
  tile = [[SmoothClipShadowTile alloc] initWithImage:image
                                              radius:tileRadius
                                              margin:margin
                                                side:side
                                               scale:scale];
  [SmoothClipShadowTileCache() setObject:tile forKey:key];
  return tile;
}

typedef void (^SmoothClipShadowTileCompletion)(SmoothClipShadowTile *tile);

@interface SmoothClipShadowTileRequest : NSObject
@property(nonatomic) CGFloat tileRadius;
@property(nonatomic) SmoothClipCornerCurve curve;
@property(nonatomic) smoothclip::Shadow shadow;
@property(nonatomic) CGFloat scale;
@property(nonatomic, readonly)
    NSMutableArray<SmoothClipShadowTileCompletion> *completions;
@end

@implementation SmoothClipShadowTileRequest
- (instancetype)init {
  if (self = [super init]) {
    _completions = [NSMutableArray array];
  }
  return self;
}
@end

// Tiles requested off the frame's critical path, in request order, one per
// main-queue drain: a block enqueued from inside a drain runs in the next
// one, so a burst of missing steps costs one bake per run-loop turn rather
// than all of them inside the transaction that asked for them.
static NSMutableArray<SmoothClipShadowTileRequest *> *SmoothClipPendingShadowTiles(void) {
  static NSMutableArray<SmoothClipShadowTileRequest *> *pending;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    pending = [NSMutableArray array];
  });
  return pending;
}

static NSMutableDictionary<NSString *, SmoothClipShadowTileRequest *> *
SmoothClipPendingShadowTilesByKey(void) {
  static NSMutableDictionary<NSString *, SmoothClipShadowTileRequest *> *pending;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    pending = [NSMutableDictionary dictionary];
  });
  return pending;
}

static BOOL gSmoothClipShadowTileBakeScheduled = NO;
static void SmoothClipScheduleShadowTileBake(void);

static void SmoothClipBakeNextShadowTile(void) {
  gSmoothClipShadowTileBakeScheduled = NO;
  NSMutableArray<SmoothClipShadowTileRequest *> *pending =
      SmoothClipPendingShadowTiles();
  SmoothClipShadowTileRequest *request = pending.firstObject;
  if (request == nil) return;
  [pending removeObjectAtIndex:0];
  [SmoothClipPendingShadowTilesByKey() removeObjectForKey:SmoothClipShadowTileKey(
      request.tileRadius, request.curve, request.shadow, request.scale)];
  SmoothClipShadowTile *tile = SmoothClipBakeShadowTile(
      request.tileRadius, request.curve, request.shadow, request.scale);
  for (SmoothClipShadowTileCompletion completion in request.completions) {
    completion(tile);
  }
  if (pending.count > 0) SmoothClipScheduleShadowTileBake();
}

static void SmoothClipScheduleShadowTileBake(void) {
  if (gSmoothClipShadowTileBakeScheduled) return;
  gSmoothClipShadowTileBakeScheduled = YES;
  dispatch_async(dispatch_get_main_queue(), ^{
    SmoothClipBakeNextShadowTile();
  });
}

// Asks for the tile without baking it now. `completion` runs on the main
// thread once the tile is cached, at once when it already is.
static void SmoothClipRequestShadowTile(
    CGFloat tileRadius,
    SmoothClipCornerCurve curve,
    const smoothclip::Shadow &shadow,
    CGFloat scale,
    SmoothClipShadowTileCompletion completion) {
  SmoothClipShadowTile *cached =
      SmoothClipCachedShadowTile(tileRadius, curve, shadow, scale);
  if (cached != nil) {
    if (completion != nil) completion(cached);
    return;
  }
  NSString *key = SmoothClipShadowTileKey(tileRadius, curve, shadow, scale);
  NSMutableDictionary<NSString *, SmoothClipShadowTileRequest *> *byKey =
      SmoothClipPendingShadowTilesByKey();
  SmoothClipShadowTileRequest *request = byKey[key];
  if (request == nil) {
    request = [SmoothClipShadowTileRequest new];
    request.tileRadius = tileRadius;
    request.curve = curve;
    request.shadow = shadow;
    request.scale = scale;
    byKey[key] = request;
    [SmoothClipPendingShadowTiles() addObject:request];
  }
  if (completion != nil) [request.completions addObject:[completion copy]];
  SmoothClipScheduleShadowTileBake();
}

NSUInteger SmoothClipShadowTileBakeCountForTesting(void) {
  return gSmoothClipShadowTileBakeCount;
}

NSUInteger SmoothClipPendingShadowTileCountForTesting(void) {
  return SmoothClipPendingShadowTiles().count;
}

void SmoothClipBakePendingShadowTilesForTesting(void) {
  while (SmoothClipPendingShadowTiles().count > 0) {
    SmoothClipBakeNextShadowTile();
  }
}

// The shadow layer's frame for a baked tile: the shape rect (aperture grown by
// the spread, then offset) plus the tile margin on every side.
static CGRect SmoothClipBakedShadowLayerRect(
    SmoothClipCanonicalGeometry geometry,
    const smoothclip::Shadow &shadow,
    CGFloat margin) {
  const CGFloat spread = shadow.spreadDistance;
  CGRect rect = CGRectInset(geometry.rect, -spread, -spread);
  if (CGRectGetWidth(rect) <= 0 || CGRectGetHeight(rect) <= 0) {
    return CGRectZero;
  }
  rect = CGRectOffset(rect, shadow.offsetX, shadow.offsetY);
  return CGRectInset(rect, -margin, -margin);
}

@implementation SmoothClipView {
  CALayer *_shadowLayer;
  SmoothClipPresentationContainerView *_presentationContainer;
  double _requestedRotation;
  double _canonicalRotation;
  double _requestedOpacity;
  double _canonicalOpacity;
  double _animationFromRotation;
  double _animationToRotation;
  // The installed run's shadow endpoints, as animated (normalized). A baked
  // tile does not carry its offset and spread as layer properties; a
  // mid-run read takes them from the run's progress
  // (smoothClipCurrentPresentation).
  smoothclip::Shadow _animationFromShadow;
  smoothclip::Shadow _animationToShadow;
  BOOL _hasAppearanceAnimation;
  BOOL _hasMaskAnimation;
  BOOL _hasShadowModel;
  SmoothClipCanonicalGeometry _shadowModelGeometry;
  smoothclip::Shadow _shadowModel;
  // `shadowRendering="baked"`: stretch one pre-blurred tile instead of
  // blurring a path every frame. See SmoothClipBakedShadowTile.
  BOOL _bakedShadows;

  SmoothClipContainerView *_clipContainer;
  SmoothClipContainerView *_contentContainer;
  CAShapeLayer *_unequalCornerMask;
  CGRect _requestedClip;
  CGRect _canonicalClip;
  CGFloat _requestedRadius;
  CGFloat _canonicalRadius;
  SmoothClipCornerRadii _requestedRadii;
  SmoothClipCornerRadii _canonicalRadii;
  SmoothClipCornerCurve _requestedCurve;
  SmoothClipCornerCurve _canonicalCurve;
  BOOL _requestedHasExplicitRadii;
  BOOL _canonicalHasExplicitRadii;
  CGPoint _requestedContentTranslation;
  CGPoint _canonicalContentTranslation;
  CGFloat _requestedContentScale;
  CGFloat _canonicalContentScale;
  smoothclip::Shadow _requestedShadow;
  smoothclip::Shadow _canonicalShadow;
  uint64_t _driverId;
  BOOL _hasLayout;
  BOOL _commandIsAuthoritative;
  // Mirrors _clipContainer.hidden/.accessibilityElementsHidden so the hot
  // path can skip UIKit getters; every write goes through setClipContainerHidden.
  BOOL _clipHidden;
  BOOL _ignoreAnimationCallback;

  int32_t _activeAnimationId;
  NSInteger _activeAnimationKind;
  smoothclip::TimingAnimation _timingAnimation;
  smoothclip::SpringAnimation _springAnimation;
  SmoothClipAnimationDelegate *_animationDelegate;
  BOOL _springPausedForInactivity;
  BOOL _pausedSpringHadMaskAnimation;
  BOOL _pausedSpringHadShadowAnimation;

  // 'inherit' velocity samples (raw canonical geometry, per view); recording/
  // coalescing/projection live in the shared cpp/SmoothClipVelocityTracker.h
  // (behavior-paired with Android's per-driver history).
  smoothclip::VelocitySampleHistory _velocitySamples;

  // Flights (`flight`, docs/flight-spec.md). The flight
  // is the lift of _presentationContainer into _flightCarrier, in the
  // window's flight layer; Fabric children stay in _contentContainer.
  BOOL _flightEnabled;
  NSString *_flightTag;
  // A transaction mounted since this host was created: its ancestors are
  // laid out, so an off-window host can compute its transform to the window.
  BOOL _flightMounted;
  UIView *_flightCarrier;
  smoothclip::HostWindowTransform _flightTransform;
  smoothclip::Presentation _flightRest;
  NSString *_flightLiftTag;
  // The target with the tag was attached and uncovered at lift: the flight
  // leaves it rather than landing on it.
  BOOL _flightDeparting;
  // A target with the tag was mounted at some point of this lift. A landing
  // flight that saw its target and has none to land on has lost it (its
  // route was popped mid-flight).
  BOOL _flightSawTarget;
  BOOL _flightInteractionHeld;
  SmoothClipFlightOutcome _flightOutcome;
  BOOL _flightLandingScheduled;
  NSUInteger _flightGeneration;
  BOOL _flightGraceStarted;
  BOOL _flightGraceExpired;
  NSHashTable *_flightAwaitedTransitions;
  // A departing flight returned while its target was still in a transition
  // (a pop): the target stays covered until that transition ends.
  BOOL _flightUncoverPending;
  // The way back: the presentation a handoff landed at, and its tag.
  BOOL _flightHasLanded;
  smoothclip::Presentation _flightLanded;
  NSString *_flightLandedTag;
  // Host loss: content snapshots taken before Fabric removes children, and
  // the content container that left with a deleted host's flight.
  BOOL _flightSnapshotTaken;
  NSMutableArray<UIView *> *_flightSnapshots;
  __weak UIView *_flightDetachedContent;
}

+ (ComponentDescriptorProvider)componentDescriptorProvider {
  return concreteComponentDescriptorProvider<SmoothClipViewComponentDescriptor>();
}

+ (BOOL)shouldBeRecycled {
  return NO;
}

#if defined(SMOOTH_CLIP_ENABLE_SIGNPOSTS) && SMOOTH_CLIP_ENABLE_SIGNPOSTS
+ (os_log_t)signpostLog {
  static os_log_t log = os_log_create(
      "com.smoothclipview", "clip-view");
  return log;
}
#endif

- (instancetype)initWithFrame:(CGRect)frame {
  if (self = [super initWithFrame:frame]) {
    static const auto defaultProps =
        std::make_shared<const SmoothClipViewProps>();
    _props = defaultProps;
    // SmoothClipView is the fixed viewport. Consumer overflow props are
    // intentionally overridden again after every prop update below.
    self.clipsToBounds = YES;

    _requestedOpacity = _canonicalOpacity = 1;
    [self buildContainers];
    _bakedShadows = NO;
    _flightTag = @"";
    _flightOutcome = SmoothClipFlightOutcomeRunning;

    _requestedClip = CGRectZero;
    _canonicalClip = CGRectZero;
    _requestedRadius = 0;
    _canonicalRadius = 0;
    _requestedRadii = {0, 0, 0, 0};
    _canonicalRadii = {0, 0, 0, 0};
    _requestedCurve = SmoothClipCornerCurveCircular;
    _canonicalCurve = SmoothClipCornerCurveCircular;
    _requestedHasExplicitRadii = NO;
    _canonicalHasExplicitRadii = NO;
    _requestedContentTranslation = CGPointZero;
    _canonicalContentTranslation = CGPointZero;
    _requestedContentScale = 1;
    _canonicalContentScale = 1;
    _requestedShadow = {};
    _canonicalShadow = {};
    _driverId = 0;
    _hasLayout = NO;
    _commandIsAuthoritative = NO;
    _ignoreAnimationCallback = NO;
    _activeAnimationId = 0;
    _activeAnimationKind = 0;
    _springPausedForInactivity = NO;
    _pausedSpringHadMaskAnimation = NO;
    _pausedSpringHadShadowAnimation = NO;
    smoothclip::clearVelocitySamples(_velocitySamples);
    // App-state transitions are observed by the registry itself (see
    // installApplicationStateObservers): the active flag is process-global,
    // so its observer must outlive any individual view.
  }
  return self;
}

- (void)dealloc {
  [self detachFlightForHostLossRebuilding:NO];
  if (_flightUncoverPending) {
    // No waiting from dealloc (it would form a weak reference to self).
    _flightUncoverPending = NO;
    [[SmoothClipFlightCoordinator shared] host:self
                                didLandWithTag:_flightLiftTag ?: @""];
  }
  if (_driverId != 0) {
    smoothclip::unregisterView(_driverId, self);
  }
}

// The library-owned containers: _presentationContainer (rotation, opacity;
// the layer a flight lifts) > _clipContainer (the aperture) >
// _contentContainer (Fabric children). A host whose flight outlives it builds
// fresh ones; the flying set stays with the flight.
- (void)buildContainers {
  _presentationContainer = [[SmoothClipPresentationContainerView alloc] initWithFrame:CGRectZero];
  _presentationContainer.layer.anchorPoint = CGPointZero;
  _presentationContainer.layer.allowsGroupOpacity = YES;
  _presentationContainer.autoresizesSubviews = NO;
  [self insertSubview:_presentationContainer atIndex:0];
  _clipContainer = [[SmoothClipContainerView alloc] initWithFrame:CGRectZero];
  _clipContainer.layer.masksToBounds = YES;
  _clipContainer.layer.needsDisplayOnBoundsChange = NO;
  _clipContainer.autoresizesSubviews = NO;
  _clipContainer.hidden = YES;
  _clipContainer.accessibilityElementsHidden = YES;
  _clipHidden = YES;
  _contentContainer =
      [[SmoothClipContainerView alloc] initWithFrame:CGRectZero];
  _contentContainer.layer.needsDisplayOnBoundsChange = NO;
  _contentContainer.autoresizesSubviews = NO;
  [_clipContainer addSubview:_contentContainer];
  [_presentationContainer addSubview:_clipContainer];

  // Created lazily so the common clipping-only path owns no shadow layer.
  _shadowLayer = nil;

  _unequalCornerMask = [CAShapeLayer layer];
  _unequalCornerMask.actions = @{
    @"path": [NSNull null],
    @"bounds": [NSNull null],
    @"position": [NSNull null],
  };
  _unequalCornerMask.fillColor = UIColor.blackColor.CGColor;
  _unequalCornerMask.needsDisplayOnBoundsChange = NO;
}

#pragma mark - Flights

// Hosts with `flight` (docs/flight-spec.md). A run, or an
// interaction, lifts _presentationContainer into a carrier in the window's
// flight layer, drawn through the host's transform to the window, so the
// first flying frame is pixel-identical to the host. The flight lands when
// the run ends: on its target (`SmoothClipFlightTarget` with the same tag),
// which is revealed in the transaction that returns the container and puts
// this host back at rest; or back in this host.

- (BOOL)smoothClipFlightWantsLift {
  return _flightEnabled || _flightCarrier != nil;
}

- (BOOL)smoothClipFlightLifted {
  return _flightCarrier != nil;
}

// The host's transform to its window from model geometry: UIKit's push and
// pop animate presentation values, so the model tree already holds where the
// host rests. A route screen that react-native-screens has not attached yet
// ends the superview chain; it is laid over its stack (`reactSuperview`).
// Nil when there is no window, or when the transform rotates, skews or
// scales unevenly (a presentation cannot express it).
- (UIWindow *)smoothClipModelWindowTransform:
    (smoothclip::HostWindowTransform *)transform {
  UIView *top = self;
  while (top.superview != nil) top = top.superview;
  UIWindow *window = nil;
  CGPoint origin = CGPointZero;
  if ([top isKindOfClass:UIWindow.class]) {
    window = (UIWindow *)top;
  } else {
    UIView *stack = top.reactSuperview;
    if (stack == nil || stack == top || stack.window == nil) return nil;
    window = stack.window;
    origin = [stack convertPoint:CGPointZero toView:nil];
  }
  const CGPoint p0 = [self convertPoint:CGPointZero toView:top];
  const CGPoint px = [self convertPoint:CGPointMake(1, 0) toView:top];
  const CGPoint py = [self convertPoint:CGPointMake(0, 1) toView:top];
  smoothclip::HostWindowTransform result;
  if (!smoothclip::hostWindowTransformFromAffine(
          px.x - p0.x, px.y - p0.y, py.x - p0.x, py.y - p0.y,
          p0.x + origin.x, p0.y + origin.y, result)) {
    return nil;
  }
  if (transform != nullptr) *transform = result;
  return window;
}

// The transform window-space presentations convert through: the one captured
// at lift while the host flies, the model one otherwise.
- (BOOL)smoothClipWindowTransform:(smoothclip::HostWindowTransform *)transform {
  if (_flightCarrier != nil) {
    *transform = _flightTransform;
    return YES;
  }
  return [self smoothClipModelWindowTransform:transform] != nil;
}

- (BOOL)smoothClipCanEnterFlight {
  return _flightEnabled && _flightMounted &&
      [self smoothClipModelWindowTransform:nullptr] != nil;
}

- (CALayer *)smoothClipRenderLayer {
  return _flightCarrier != nil ? _presentationContainer.layer : self.layer;
}

// Called by the registry when a run starts on this host (before its start
// presentation applies) and when an interaction begins on it. `rest` is what
// the host shows now: a handoff puts it back there. A host that already flies
// continues in the same lift.
- (void)smoothClipLiftForFlightWithRest:(smoothclip::Presentation)rest
                            interaction:(BOOL)interaction {
  if (![self smoothClipFlightWantsLift]) return;
  _flightInteractionHeld = interaction;
  _flightOutcome = SmoothClipFlightOutcomeRunning;
  if (_flightCarrier != nil) return;

  smoothclip::HostWindowTransform transform;
  UIWindow *window = [self smoothClipModelWindowTransform:&transform];
  if (window == nil) return;
  [self finishPendingFlightUncover];
  SmoothClipFlightCoordinator *coordinator = [SmoothClipFlightCoordinator shared];
  NSString *tag = [_flightTag copy] ?: @"";
  SmoothClipFlightTargetView *target = [coordinator attachedTargetForTag:tag];

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  UIView *carrier = [[SmoothClipFlightCarrierView alloc] initWithFrame:CGRectZero];
  // A flight may leave the host's bounds (a grid tile flying full screen):
  // the aperture alone bounds what shows.
  carrier.clipsToBounds = NO;
  carrier.userInteractionEnabled = NO;
  CALayer *layer = carrier.layer;
  layer.anchorPoint = CGPointZero;
  layer.bounds = self.bounds;
  layer.position = CGPointZero;
  // A host point p shows at scale * p + translate; the layer maps a bounds
  // point p to position + affine(p - bounds.origin).
  const double scale = transform.scale;
  const CGPoint boundsOrigin = self.bounds.origin;
  layer.affineTransform = CGAffineTransformMake(
      scale, 0, 0, scale,
      transform.translateX + scale * boundsOrigin.x,
      transform.translateY + scale * boundsOrigin.y);
  [[coordinator flightLayerForWindow:window] addSubview:carrier];
  [carrier addSubview:_presentationContainer];
  [CATransaction commit];

  _flightCarrier = carrier;
  _flightTransform = transform;
  _flightRest = rest;
  _flightLiftTag = tag;
  _flightDeparting = target != nil && !target.flightCovered;
  _flightSawTarget = [coordinator registeredTargetForTag:tag] != nil;
  _flightGeneration += 1;
  _flightGraceStarted = NO;
  _flightGraceExpired = NO;
  _flightSnapshotTaken = NO;
  _flightDetachedContent = nil;
  // The way back is consumed (or stale) once the host flies again.
  _flightHasLanded = NO;
  _flightLandedTag = nil;
  [coordinator host:self didLiftWithTag:tag];

}

// The registry ended this host's run (finished, or replaced, cancelled,
// frozen by an interaction), before it reports the completion.
// - Finished: nothing replaces the run in this call, so the landing is
//   evaluated now. A handoff resets the host to rest before the completion
//   is sent, so JS sees the rest frame; a landing that waits (`ready`, a
//   transition) leaves the landed frame for the completion to report.
// - Otherwise: a replacement may start its own run in the same call, so the
//   landing is evaluated after it, from the main queue.
- (void)smoothClipFlightRunDidEnd:(BOOL)finished {
  if (_flightCarrier == nil) return;
  _flightOutcome = finished ? SmoothClipFlightOutcomeFinished
                            : SmoothClipFlightOutcomeCancelled;
  if (finished) {
    [self evaluateFlightLanding];
    return;
  }
  [self scheduleFlightLanding];
}

- (void)scheduleFlightLanding {
  if (_flightLandingScheduled) return;
  _flightLandingScheduled = YES;
  __weak SmoothClipView *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    SmoothClipView *strongSelf = weakSelf;
    if (strongSelf == nil) return;
    strongSelf->_flightLandingScheduled = NO;
    [strongSelf evaluateFlightLanding];
  });
}

// The way back: a run with no `from` on a host whose flight handed off to a
// target that is still attached and visible starts where that flight landed.
- (BOOL)smoothClipFlightWayBackFrom:(smoothclip::Presentation *)from {
  if (!_flightHasLanded || _flightCarrier != nil || _flightLandedTag.length == 0) {
    return NO;
  }
  SmoothClipFlightTargetView *target =
      [[SmoothClipFlightCoordinator shared] attachedTargetForTag:_flightLandedTag];
  if (target == nil || target.flightCovered) return NO;
  *from = _flightLanded;
  return YES;
}

// The app moved the host itself (setFrame): a landed record no longer
// describes where it is.
- (void)smoothClipFlightForgetLanding {
  _flightHasLanded = NO;
  _flightLandedTag = nil;
}

#pragma mark SmoothClipFlightHost

- (void)smoothClipFlightTargetsDidChange {
  if (_flightCarrier != nil) {
    const BOOL registered = [[SmoothClipFlightCoordinator shared]
        registeredTargetForTag:_flightLiftTag] != nil;
    if (registered) _flightSawTarget = YES;
    if (_flightInteractionHeld && _flightDeparting && !registered) {
      // An interaction that left a target that has now unmounted: the route
      // that drove it (following its own dismissal) is gone, and nothing will
      // start the run that would end it. It lands as a flight that lost its
      // target, with the host back at rest; held, it would stay above every
      // screen with its content for good.
      _flightInteractionHeld = NO;
      _flightDeparting = NO;
      _flightSawTarget = YES;
      _flightOutcome = SmoothClipFlightOutcomeFinished;
    }
    [self evaluateFlightLanding];
  } else {
    [self finishPendingFlightUncover];
  }
}

#pragma mark Landing

// Every trigger lands here: the run's end, this host's window and screen
// transition, target changes (registration, attach, `ready`, transitions)
// and the 300 ms grace for a detached host.
- (void)evaluateFlightLanding {
  if (_flightCarrier == nil) return;
  if (_flightInteractionHeld || _activeAnimationId != 0) return;
  if (_driverId != 0 && smoothclip::hasActiveAnimation(_driverId)) return;
  if (_flightOutcome != SmoothClipFlightOutcomeFinished) {
    // Cancelled (never handed off): land in place, reveal the target.
    [self returnFromFlightHandingOffTo:nil restingHost:NO];
    return;
  }
  if (!_flightDeparting) {
    SmoothClipFlightCoordinator *coordinator = [SmoothClipFlightCoordinator shared];
    SmoothClipFlightTargetView *target =
        [coordinator attachedTargetForTag:_flightLiftTag];
    if (target != nil) {
      // Wait: the content holds the run's last frame in the layer until the
      // target can take over (`ready` and transitions notify).
      if (!target.flightReady) return;
      if (target.flightInTransition) {
        [self awaitTransitionOfView:target];
        return;
      }
      [self returnFromFlightHandingOffTo:target restingHost:YES];
      return;
    }
    // A target that is mounted but not attached yet is arriving (a pushed
    // screen attaches one message after its mount) for the grace period:
    // returning now would flash the flown content back in the host.
    if (!_flightGraceExpired &&
        [coordinator registeredTargetForTag:_flightLiftTag] != nil) {
      [self startFlightGrace];
      return;
    }
  }
  // Departing, or no target: back into the host once it is on screen.
  //
  // Lost target: a landing flight that saw its target and has none attached
  // now (the route was popped mid-flight and nothing flew the host home, or
  // its screen never attached). The flight arrived somewhere that is gone,
  // so it lands as a handoff with nothing to reveal: the host goes back to
  // rest. Returning it where it landed would leave it at the destination
  // frame on its own screen for good.
  const BOOL lostTarget = !_flightDeparting && _flightSawTarget;
  if (self.window != nil) {
    if (SmoothClipViewIsInTransition(self)) {
      [self awaitTransitionOfView:self];
      return;
    }
    [self returnFromFlightHandingOffTo:nil restingHost:lostTarget];
    return;
  }
  // Fallback: a detached host waits for its screen, or for the grace period.
  if (_flightGraceExpired) {
    [self returnFromFlightHandingOffTo:nil restingHost:lostTarget];
    return;
  }
  [self startFlightGrace];
}

// 300 ms from the first landing evaluation that had to wait for a host or a
// target to attach; once, per lift.
- (void)startFlightGrace {
  if (_flightGraceStarted) return;
  _flightGraceStarted = YES;
  const NSUInteger generation = _flightGeneration;
  __weak SmoothClipView *weakSelf = self;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        SmoothClipView *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf->_flightGeneration != generation ||
            strongSelf->_flightCarrier == nil) {
          return;
        }
        strongSelf->_flightGraceExpired = YES;
        [strongSelf evaluateFlightLanding];
      });
}

- (void)awaitTransitionOfView:(UIView *)view {
  id<UIViewControllerTransitionCoordinator> transition =
      SmoothClipViewTransitionCoordinator(view);
  if (transition == nil) return;
  if (_flightAwaitedTransitions == nil) {
    _flightAwaitedTransitions = [NSHashTable weakObjectsHashTable];
  }
  if ([_flightAwaitedTransitions containsObject:transition]) return;
  [_flightAwaitedTransitions addObject:transition];
  __weak SmoothClipView *weakSelf = self;
  SmoothClipObserveTransitionEnd(view, ^{
    [weakSelf smoothClipFlightTargetsDidChange];
  });
}

// Ends the lift in one transaction. With a target (the handoff): reveal it,
// return the container, put the host back at rest and remember where the
// flight landed for the way back. Without: return the container and reveal
// any covered target; the host stays where the flight left it, unless it
// lost its target (`rest`), which lands as a handoff with nothing to reveal.
- (void)returnFromFlightHandingOffTo:(SmoothClipFlightTargetView *)target
                         restingHost:(BOOL)rest {
  if (_flightCarrier == nil) return;
  SmoothClipFlightCoordinator *coordinator = [SmoothClipFlightCoordinator shared];
  NSString *tag = _flightLiftTag ?: @"";
  BOOL keepCovered = NO;
  if (target == nil && _flightDeparting) {
    // A departing flight whose target is still on its way out (a pop):
    // revealing it now would show it beside its own flight.
    SmoothClipFlightTargetView *departed = [coordinator attachedTargetForTag:tag];
    keepCovered = departed != nil && departed.flightInTransition;
    if (keepCovered) [self awaitTransitionOfView:departed];
  }
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  if (keepCovered) {
    _flightUncoverPending = YES;
  } else {
    [coordinator host:self didLandWithTag:tag];
  }
  [self insertSubview:_presentationContainer atIndex:0];
  if (rest) {
    smoothclip::Presentation landed;
    if (_driverId == 0 ||
        !smoothclip::settleFlightHost(_driverId, _flightRest, landed)) {
      landed = [self smoothClipCurrentPresentation];
      [self smoothClipApplyPresentation:_flightRest recordVelocitySample:NO];
    }
    _flightLanded = landed;
    _flightHasLanded = YES;
    _flightLandedTag = tag;
  }
  [_flightCarrier removeFromSuperview];
  _flightCarrier = nil;
  for (UIView *snapshot in _flightSnapshots) [snapshot removeFromSuperview];
  [_flightSnapshots removeAllObjects];
  [CATransaction commit];
  _flightGeneration += 1;
  _flightInteractionHeld = NO;
  if (target != nil && UIAccessibilityIsVoiceOverRunning()) {
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, target);
  }
}

- (void)finishPendingFlightUncover {
  if (!_flightUncoverPending) return;
  SmoothClipFlightCoordinator *coordinator = [SmoothClipFlightCoordinator shared];
  NSString *tag = _flightLiftTag ?: @"";
  SmoothClipFlightTargetView *departed = [coordinator attachedTargetForTag:tag];
  if (departed != nil && departed.flightInTransition && _flightCarrier == nil) {
    [self awaitTransitionOfView:departed];
    return;
  }
  _flightUncoverPending = NO;
  [coordinator host:self didLandWithTag:tag];
}

#pragma mark Host loss

// The host is going away mid-flight (a pop deletes the route's views, or its
// controller is destroyed). The flying containers stay in the carrier with
// their Core Animation run; a keeper lands them when the run would have
// ended. The host lets go of them and builds fresh ones, so the registry's
// host-loss freeze never touches the flying layers.
- (void)smoothClipDetachFlightForHostLoss {
  [self detachFlightForHostLossRebuilding:YES];
}

- (void)detachFlightForHostLossRebuilding:(BOOL)rebuild {
  if (_flightCarrier == nil) return;
  CFTimeInterval remaining = 0;
  CAAnimation *geometry = _activeAnimationId != 0
      ? [_clipContainer.layer animationForKey:@"smoothClip.geometry"]
      : nil;
  if (geometry != nil && geometry.speed != 0) {
    const CFTimeInterval begin =
        [_clipContainer.layer convertTime:geometry.beginTime toLayer:nil];
    remaining = MAX(0, begin + geometry.duration - CACurrentMediaTime());
  }
  SmoothClipFlightKeeper *keeper = [SmoothClipFlightKeeper new];
  keeper.carrier = _flightCarrier;
  keeper.tag = _flightLiftTag ?: @"";
  SmoothClipFlightCoordinator *coordinator = [SmoothClipFlightCoordinator shared];
  [coordinator host:keeper didLiftWithTag:keeper.tag];
  [coordinator host:self didLandWithTag:keeper.tag];

  // The run keeps flying on the old layers; none of it reaches this host.
  _animationDelegate.invalidated = YES;
  _animationDelegate = nil;
  _activeAnimationId = 0;
  _activeAnimationKind = 0;
  _springPausedForInactivity = NO;
  _pausedSpringHadMaskAnimation = NO;
  _pausedSpringHadShadowAnimation = NO;
  _hasAppearanceAnimation = NO;
  _hasMaskAnimation = NO;
  _flightDetachedContent = _contentContainer;
  _flightCarrier = nil;
  _flightInteractionHeld = NO;
  _flightGeneration += 1;
  [_flightSnapshots removeAllObjects];
  if (rebuild) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self buildContainers];
    [self resetCanonicalPresentationState];
    if (_hasLayout) [self layoutContentContainer];
    [self applyRequestedClip];
    [CATransaction commit];
  } else {
    // dealloc: the registry's host-loss freeze that follows must not write
    // into the flying layers.
    _presentationContainer = nil;
    _clipContainer = nil;
    _contentContainer = nil;
    _shadowLayer = nil;
    _unequalCornerMask = nil;
  }
  [keeper landAfter:remaining];
}

// Fresh containers show nothing yet: forget what the old ones showed, so the
// next write reaches every layer.
- (void)resetCanonicalPresentationState {
  _canonicalClip = CGRectZero;
  _canonicalRadius = 0;
  _canonicalRadii = {0, 0, 0, 0};
  _canonicalCurve = SmoothClipCornerCurveCircular;
  _canonicalHasExplicitRadii = NO;
  _canonicalContentTranslation = CGPointZero;
  _canonicalContentScale = 1;
  _canonicalShadow = {};
  _canonicalRotation = 0;
  _canonicalOpacity = 1;
  _hasShadowModel = NO;
}

// A pop deletes the route's views while the hero flies back. Fabric removes
// leaves first (an Image from its wrapper before the wrapper from this host),
// so the content is captured once, before any of those removals; the host's
// Delete hands the flight to a keeper. Only a flying host (or one whose
// flight left with its content) does any work here.
//
// A flying host that stays keeps its content live: a transaction that only
// removes one of its children (a spinner unmounting when an image loads) is
// an ordinary update, and a snapshot there would freeze the content, spinner
// included, until the flight lands. The snapshot is for content that is
// about to lose its host: this transaction deletes it, or the flight already
// left with a keeper.
- (void)mountingTransactionWillMount:(const facebook::react::MountingTransaction &)transaction
                withSurfaceTelemetry:(const facebook::react::SurfaceTelemetry &)surfaceTelemetry {
  UIView *content = _flightCarrier != nil ? _contentContainer : _flightDetachedContent;
  if (content == nil || (_flightCarrier == nil && _flightSnapshotTaken)) return;
  const auto tag = static_cast<facebook::react::Tag>(self.tag);
  BOOL deletesHost = NO;
  BOOL removesChild = NO;
  for (const auto &mutation : transaction.getMutations()) {
    if (mutation.type == ShadowViewMutation::Delete &&
        mutation.oldChildShadowView.tag == tag) {
      deletesHost = YES;
      break;
    }
    if (mutation.type == ShadowViewMutation::Remove && mutation.parentTag == tag) {
      removesChild = YES;
    }
  }
  const BOOL orphaned = _flightCarrier == nil;
  if (!deletesHost && !(orphaned && removesChild)) return;
  if (!_flightSnapshotTaken) {
    _flightSnapshotTaken = YES;
    UIView *snapshot = [content snapshotViewAfterScreenUpdates:NO];
    if (snapshot != nil) {
      snapshot.frame = content.bounds;
      [content addSubview:snapshot];
      if (_flightSnapshots == nil) _flightSnapshots = [NSMutableArray array];
      [_flightSnapshots addObject:snapshot];
    }
  }
  if (deletesHost) [self smoothClipDetachFlightForHostLoss];
}

- (void)mountingTransactionDidMount:(const facebook::react::MountingTransaction &)transaction
               withSurfaceTelemetry:(const facebook::react::SurfaceTelemetry &)surfaceTelemetry {
  if (!_flightEnabled || _flightMounted) return;
  _flightMounted = YES;
  if (_driverId != 0) smoothclip::viewDisplayabilityChanged(_driverId, self);
}

- (void)didMoveToWindow {
  [super didMoveToWindow];
  if (_driverId != 0) {
    smoothclip::viewDisplayabilityChanged(_driverId, self);
  }
  if (_flightCarrier != nil) [self evaluateFlightLanding];
}

- (void)mountChildComponentView:(UIView<RCTComponentViewProtocol> *)childComponentView
                          index:(NSInteger)index {
  NSAssert(childComponentView.superview == nil,
           @"SmoothClipView attempted to mount an already-mounted child");
  [_contentContainer insertSubview:childComponentView atIndex:index];
}

- (void)unmountChildComponentView:(UIView<RCTComponentViewProtocol> *)childComponentView
                            index:(NSInteger)index {
  UIView *parent = childComponentView.superview;
  if (parent != _contentContainer &&
      [parent isKindOfClass:SmoothClipContainerView.class]) {
    // It left with a flight that outlived this host (a snapshot of it flies
    // on, mountingTransactionWillMount).
    [childComponentView removeFromSuperview];
    return;
  }
  NSAssert(childComponentView.superview == _contentContainer,
           @"SmoothClipView attempted to unmount a child from another parent");
  NSAssert(index < _contentContainer.subviews.count &&
               _contentContainer.subviews[index] == childComponentView,
           @"SmoothClipView child index mismatch");
  [childComponentView removeFromSuperview];
}

- (void)storeRequestedPresentation:(smoothclip::Presentation)presentation {
  const smoothclip::Geometry geometry = presentation.clip;
  _requestedClip = CGRectMake(
      geometry.x,
      geometry.y,
      MAX(0, geometry.width),
      MAX(0, geometry.height));
  _requestedRadii = SmoothClipPresentationRadii(geometry);
  _requestedRadius = SmoothClipCornerRadiiAreUniform(_requestedRadii)
      ? MAX(0, _requestedRadii.topLeft)
      : 0;
  _requestedCurve = SmoothClipPresentationCurve(geometry);
  _requestedHasExplicitRadii =
      SmoothClipPresentationHasExplicitRadii(geometry);
  _requestedContentTranslation = CGPointMake(
      presentation.contentTranslateX,
      presentation.contentTranslateY);
  _requestedContentScale = presentation.contentScale;
  _requestedShadow = presentation.shadow;
  _requestedRotation = presentation.rotation;
  _requestedOpacity = smoothclip::clamp01(presentation.opacity);
}

- (CGColorRef)colorForShadow:(const smoothclip::Shadow &)shadow {
  return [UIColor colorWithRed:smoothclip::clamp01(shadow.red)
                         green:smoothclip::clamp01(shadow.green)
                          blue:smoothclip::clamp01(shadow.blue)
                         alpha:smoothclip::clamp01(shadow.alpha)].CGColor;
}

- (CALayer *)ensureShadowLayer {
  if (_shadowLayer != nil) return _shadowLayer;
  _shadowLayer = [CALayer layer];
  _shadowLayer.masksToBounds = NO;
  _shadowLayer.actions = @{
    @"shadowPath": [NSNull null],
    @"shadowColor": [NSNull null],
    @"shadowOpacity": [NSNull null],
    @"shadowRadius": [NSNull null],
    @"shadowOffset": [NSNull null],
    @"bounds": [NSNull null],
    @"position": [NSNull null],
    @"opacity": [NSNull null],
    @"contents": [NSNull null],
    @"contentsCenter": [NSNull null],
    @"contentsScale": [NSNull null],
  };
  [_presentationContainer.layer insertSublayer:_shadowLayer below:_clipContainer.layer];
  return _shadowLayer;
}

- (CGFloat)bakedShadowScale {
  const CGFloat scale = self.traitCollection.displayScale;
  return scale > 0 ? scale : UIScreen.mainScreen.scale;
}

// Radius step of the tile a geometry's shadow draws from.
- (CGFloat)bakedShadowTileRadiusForGeometry:(SmoothClipCanonicalGeometry)geometry
                                     shadow:(const smoothclip::Shadow &)shadow {
  return SmoothClipBakedShadowTileRadius(SmoothClipAdjustedShadowRadius(
      geometry.radii.topLeft, shadow.spreadDistance));
}

- (BOOL)usesBakedShadowForGeometry:(SmoothClipCanonicalGeometry)geometry
                            shadow:(const smoothclip::Shadow &)shadow {
  // Unequal radii have no single tile; they keep the blur path. So does a
  // shape too small for two corner slices on a side, 2 x (margin + radius):
  // the compositor would squash the slices rather than overlap the blur
  // tails the way the true shadow does.
  if (!_bakedShadows || !SmoothClipCornerRadiiAreUniform(geometry.radii)) {
    return NO;
  }
  const CGFloat minimumSide = 2 *
      (SmoothClipBakedShadowMargin(shadow) +
       [self bakedShadowTileRadiusForGeometry:geometry shadow:shadow]);
  const CGFloat spread = 2 * shadow.spreadDistance;
  return CGRectGetWidth(geometry.rect) + spread >= minimumSide &&
      CGRectGetHeight(geometry.rect) + spread >= minimumSide;
}

// A requested tile is cached: draw it, if the model still wants it and
// nothing else owns the layer (a run in flight swaps tiles from its own
// keyframes, and its completion writes the model again).
- (void)shadowTileDidLand:(SmoothClipShadowTile *)tile {
  if (tile == nil || _activeAnimationId != 0 || !_hasShadowModel ||
      _shadowLayer == nil ||
      ![self usesBakedShadowForGeometry:_shadowModelGeometry
                                 shadow:_shadowModel]) {
    return;
  }
  const CGFloat wanted = [self bakedShadowTileRadiusForGeometry:_shadowModelGeometry
                                                         shadow:_shadowModel];
  if (SmoothClipCachedShadowTile(wanted, _shadowModelGeometry.curve,
                                 _shadowModel, [self bakedShadowScale]) != tile ||
      _shadowLayer.contents == (__bridge id)tile.image) {
    return;
  }
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [self writeBakedShadowModel:_shadowModel
                     geometry:_shadowModelGeometry
                      visible:SmoothBoxShadowVisible(_shadowModelGeometry, _shadowModel)
                  nearestTile:NO
                        layer:_shadowLayer];
  [CATransaction commit];
}

// `allowNearest`: a missing tile may be stood in for by the nearest cached
// step until the exact one lands (a drag crossing a step, a model write); a
// run's resting target passes NO and bakes now, so its last frame is exact.
- (void)writeBakedShadowModel:(const smoothclip::Shadow &)shadow
                     geometry:(SmoothClipCanonicalGeometry)geometry
                      visible:(BOOL)visible
                  nearestTile:(BOOL)allowNearest
                        layer:(CALayer *)shadowLayer {
  SmoothClipShadowTile *tile = nil;
  if (visible) {
    const CGFloat tileRadius =
        [self bakedShadowTileRadiusForGeometry:geometry shadow:shadow];
    const CGFloat scale = [self bakedShadowScale];
    tile = SmoothClipCachedShadowTile(tileRadius, geometry.curve, shadow, scale);
    if (tile == nil && allowNearest) {
      tile = SmoothClipNearestCachedShadowTile(
          tileRadius, geometry.curve, shadow, scale);
      if (tile != nil) {
        // A neighbouring step for now (one step off is invisible under the
        // blur the tile was made for); the exact tile lands off this frame.
        __weak SmoothClipView *weakSelf = self;
        SmoothClipRequestShadowTile(
            tileRadius, geometry.curve, shadow, scale,
            ^(SmoothClipShadowTile *exact) {
              [weakSelf shadowTileDidLand:exact];
            });
      }
    }
    if (tile == nil) {
      // Nothing near enough to show meanwhile (a cold cache, at mount), or a
      // resting target that must be exact.
      tile = SmoothClipBakeShadowTile(tileRadius, geometry.curve, shadow, scale);
    }
  }
  // Leave no blur-path state behind: a tile layer that kept a shadowPath
  // would draw both.
  if (shadowLayer.shadowPath != NULL) shadowLayer.shadowPath = NULL;
  shadowLayer.shadowOpacity = 0;
  if (tile == nil) {
    shadowLayer.opacity = 0;
    return;
  }
  if (shadowLayer.contents != (__bridge id)tile.image) {
    shadowLayer.contents = (__bridge id)tile.image;
    shadowLayer.contentsCenter = tile.contentsCenter;
    shadowLayer.contentsScale = tile.scale;
    shadowLayer.contentsGravity = kCAGravityResize;
  }
  const CGRect rect =
      SmoothClipBakedShadowLayerRect(geometry, shadow, tile.margin);
  shadowLayer.bounds = CGRectMake(0, 0, rect.size.width, rect.size.height);
  shadowLayer.position =
      CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
  shadowLayer.opacity = smoothclip::clamp01(shadow.alpha);
}

- (void)writeShadowModel:(const smoothclip::Shadow &)shadow
                 geometry:(SmoothClipCanonicalGeometry)geometry {
  [self writeShadowModel:shadow
                geometry:geometry
                   baked:[self usesBakedShadowForGeometry:geometry shadow:shadow]
             nearestTile:YES];
}

- (void)writeShadowModel:(const smoothclip::Shadow &)shadow
                 geometry:(SmoothClipCanonicalGeometry)geometry
                    baked:(BOOL)baked
              nearestTile:(BOOL)allowNearest {
  const smoothclip::Shadow effectiveShadow =
      SmoothBoxShadowWithEffectiveAlpha(geometry, shadow);
  const BOOL visible = SmoothBoxShadowVisible(geometry, effectiveShadow);
  if (_shadowLayer == nil && !visible) return;

  CALayer *shadowLayer = visible ? [self ensureShadowLayer] : _shadowLayer;
  const BOOL pathInputChanged = !_hasShadowModel ||
      !SmoothBoxShadowPathInputEqual(
          _shadowModelGeometry, _shadowModel, geometry, effectiveShadow);
  _hasShadowModel = YES;
  _shadowModelGeometry = geometry;
  _shadowModel = effectiveShadow;
  if (baked) {
    [self writeBakedShadowModel:effectiveShadow
                       geometry:geometry
                        visible:visible
                    nearestTile:allowNearest
                          layer:shadowLayer];
    return;
  }
  BOOL leftTile = NO;
  if (shadowLayer.contents != nil) {
    // Back from a baked tile: the blur path draws at layer opacity 1 with
    // the alpha in shadowColor, and needs its path again.
    shadowLayer.contents = nil;
    shadowLayer.opacity = 1;
    leftTile = YES;
  }
  shadowLayer.bounds = self.bounds;
  shadowLayer.position = CGPointMake(
      CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
  if (pathInputChanged || leftTile) {
    CGPathRef path = SmoothClipCreateShadowPath(geometry, effectiveShadow);
    shadowLayer.shadowPath = path;
    CGPathRelease(path);
  }
  shadowLayer.shadowColor = [self colorForShadow:effectiveShadow];
  shadowLayer.shadowOpacity = visible ? 1 : 0;
  shadowLayer.shadowRadius = MAX(0, effectiveShadow.blurRadius) / 2.0;
  shadowLayer.shadowOffset = CGSizeMake(
      effectiveShadow.offsetX, effectiveShadow.offsetY);
}

// Animations for a baked shadow run. Bounds, position and opacity
// interpolate; the tile (radius step, blur, colour) is categorical, so it steps
// at the key times where the run's progress crosses each radius step, with the
// target's blur and colour from the first swap on. Steps are one radius step
// apart, invisible under any blur the tile was made for.
- (NSArray<CAAnimation *> *)bakedShadowAnimationsFromGeometry:
                                (SmoothClipCanonicalGeometry)fromGeometry
                                  fromShadow:(smoothclip::Shadow)fromShadow
                                  toGeometry:(SmoothClipCanonicalGeometry)toGeometry
                                    toShadow:(smoothclip::Shadow)toShadow
                                      timing:(CAMediaTimingFunction *)timing
                                      spring:(BOOL)spring
                                    velocity:(double)velocity
                                    duration:(CFTimeInterval)duration {
  const CGFloat scale = [self bakedShadowScale];
  const CGFloat fromRadius =
      [self bakedShadowTileRadiusForGeometry:fromGeometry shadow:fromShadow];
  const CGFloat toRadius =
      [self bakedShadowTileRadiusForGeometry:toGeometry shadow:toShadow];
  // The start is whatever the model shows (its step or a stand-in); the
  // target was baked by the model write just before this and must be exact.
  SmoothClipShadowTile *fromTile = SmoothClipNearestCachedShadowTile(
      fromRadius, fromGeometry.curve, fromShadow, scale);
  if (fromTile == nil) {
    fromTile = SmoothClipBakeShadowTile(
        fromRadius, fromGeometry.curve, fromShadow, scale);
  }
  SmoothClipShadowTile *toTile = SmoothClipBakeShadowTile(
      toRadius, toGeometry.curve, toShadow, scale);
  const CGFloat fromMargin = fromTile != nil
      ? fromTile.margin : SmoothClipBakedShadowMargin(fromShadow);
  const CGFloat toMargin = toTile != nil
      ? toTile.margin : SmoothClipBakedShadowMargin(toShadow);
  const CGRect fromRect =
      SmoothClipBakedShadowLayerRect(fromGeometry, fromShadow, fromMargin);
  const CGRect toRect =
      SmoothClipBakedShadowLayerRect(toGeometry, toShadow, toMargin);
  NSMutableArray<CAAnimation *> *animations = [NSMutableArray array];
  const auto add = [&](NSString *keyPath, id from, id to) {
    [animations addObject:spring
        ? [self springAnimationForKeyPath:keyPath fromValue:from toValue:to
                                 velocity:velocity duration:duration]
        : [self basicAnimationForKeyPath:keyPath fromValue:from toValue:to
                          timingFunction:timing]];
  };
  if (!CGSizeEqualToSize(fromRect.size, toRect.size)) {
    add(@"bounds",
        [NSValue valueWithCGRect:CGRectMake(
            0, 0, fromRect.size.width, fromRect.size.height)],
        [NSValue valueWithCGRect:CGRectMake(
            0, 0, toRect.size.width, toRect.size.height)]);
  }
  const CGPoint fromCenter =
      CGPointMake(CGRectGetMidX(fromRect), CGRectGetMidY(fromRect));
  const CGPoint toCenter =
      CGPointMake(CGRectGetMidX(toRect), CGRectGetMidY(toRect));
  if (!CGPointEqualToPoint(fromCenter, toCenter)) {
    add(@"position",
        [NSValue valueWithCGPoint:fromCenter],
        [NSValue valueWithCGPoint:toCenter]);
  }
  if (fromShadow.alpha != toShadow.alpha) {
    add(@"opacity", @(smoothclip::clamp01(fromShadow.alpha)),
        @(smoothclip::clamp01(toShadow.alpha)));
  }
  if (fromTile == nil || toTile == nil || fromTile == toTile) {
    return animations;
  }

  NSMutableArray *images = [NSMutableArray arrayWithObject:(__bridge id)fromTile.image];
  NSMutableArray<NSValue *> *centers =
      [NSMutableArray arrayWithObject:[NSValue valueWithCGRect:fromTile.contentsCenter]];
  NSMutableArray<NSNumber *> *keyTimes = [NSMutableArray arrayWithObject:@0];
  const CGFloat rawFrom = SmoothClipAdjustedShadowRadius(
      fromGeometry.radii.topLeft, fromShadow.spreadDistance);
  const CGFloat rawTo = SmoothClipAdjustedShadowRadius(
      toGeometry.radii.topLeft, toShadow.spreadDistance);
  // Normalised time at which the run's progress first reaches `target`.
  const auto timeForProgress = [&](double target) -> double {
    if (target <= 0) return 0;
    if (target >= 1) return 1;
    constexpr double step = 1.0 / 240.0;
    if (spring) {
      smoothclip::ScalarSpringState state{0, velocity};
      double elapsed = 0;
      while (elapsed < duration) {
        state = smoothclip::advanceScalarSpring(state, _springAnimation, step);
        elapsed += step;
        if (state.position >= target) break;
      }
      return duration > 0 ? std::min(1.0, elapsed / duration) : 1.0;
    }
    double low = 0, high = 1;
    for (int iteration = 0; iteration < 20; iteration += 1) {
      const double middle = (low + high) / 2;
      const double progress = smoothclip::cubicBezier(
          _timingAnimation.controlPoint1X, _timingAnimation.controlPoint1Y,
          _timingAnimation.controlPoint2X, _timingAnimation.controlPoint2Y,
          middle);
      if (progress < target) low = middle; else high = middle;
    }
    return (low + high) / 2;
  };
  if (fromTile.radius == toTile.radius || rawTo == rawFrom) {
    // Same radius step, a different blur or colour: one swap, mid-run.
    [images addObject:(__bridge id)toTile.image];
    [centers addObject:[NSValue valueWithCGRect:toTile.contentsCenter]];
    [keyTimes addObject:@0.5];
  } else {
    const BOOL growing = toTile.radius > fromTile.radius;
    const CGFloat step = kSmoothClipShadowTileRadiusStep * (growing ? 1 : -1);
    // Key time a missing step hands to the next cached tile on a growing run.
    double carriedTime = -1;
    for (CGFloat tileRadius = fromTile.radius + step;
         growing ? tileRadius <= toTile.radius : tileRadius >= toTile.radius;
         tileRadius += step) {
      // Rounding up: a growing radius takes tile T once it passes T - step,
      // a shrinking one once it reaches T.
      const CGFloat threshold = growing
          ? tileRadius - kSmoothClipShadowTileRadiusStep : tileRadius;
      const double progress = (threshold - rawFrom) / (rawTo - rawFrom);
      SmoothClipShadowTile *tile = SmoothClipCachedShadowTile(
          tileRadius, toGeometry.curve, toShadow, scale);
      if (tile == nil) {
        // Not baked inside this transaction: it lands for the next run. A
        // growing run swaps to the next cached (rounder) tile at this step's
        // time instead, so the shown corner is never tighter than the clip's;
        // a shrinking run simply keeps the rounder tile a step longer.
        SmoothClipRequestShadowTile(
            tileRadius, toGeometry.curve, toShadow, scale, nil);
        if (growing && carriedTime < 0) carriedTime = timeForProgress(progress);
        continue;
      }
      const double ownTime = timeForProgress(progress);
      const double time = std::max(
          keyTimes.lastObject.doubleValue,
          carriedTime >= 0 ? std::min(carriedTime, ownTime) : ownTime);
      carriedTime = -1;
      if (time <= keyTimes.lastObject.doubleValue + 1e-6) {
        // Same instant as the previous swap (leaving a step value at t = 0):
        // the later tile is the one shown; key times must strictly increase.
        images[images.count - 1] = (__bridge id)tile.image;
        centers[centers.count - 1] = [NSValue valueWithCGRect:tile.contentsCenter];
        continue;
      }
      [images addObject:(__bridge id)tile.image];
      [centers addObject:[NSValue valueWithCGRect:tile.contentsCenter]];
      [keyTimes addObject:@(time)];
    }
  }
  if (images.count < 2) return animations;
  // Discrete key times bracket their values: one more entry than values, the
  // last at 1 (CAKeyframeAnimation.keyTimes). Without the closing entry Core
  // Animation ignores the array and spaces the swaps evenly over the run.
  [keyTimes addObject:@1];
  CAKeyframeAnimation *contents =
      [CAKeyframeAnimation animationWithKeyPath:@"contents"];
  contents.values = images;
  contents.keyTimes = keyTimes;
  contents.calculationMode = kCAAnimationDiscrete;
  contents.duration = duration;
  [animations addObject:contents];
  CAKeyframeAnimation *contentsCenter =
      [CAKeyframeAnimation animationWithKeyPath:@"contentsCenter"];
  contentsCenter.values = centers;
  contentsCenter.keyTimes = keyTimes;
  contentsCenter.calculationMode = kCAAnimationDiscrete;
  contentsCenter.duration = duration;
  [animations addObject:contentsCenter];
  return animations;
}

- (void)writeShadow:(const smoothclip::Shadow &)shadow
            geometry:(SmoothClipCanonicalGeometry)geometry {
  _canonicalShadow = shadow;
  [self writeShadowModel:shadow geometry:geometry];
}

- (BOOL)canonicalRequestedGeometry:(SmoothClipCanonicalGeometry *)geometry {
  if (!_hasLayout) return NO;
#if defined(SMOOTH_CLIP_ENABLE_SIGNPOSTS) && SMOOTH_CLIP_ENABLE_SIGNPOSTS
  const bool signpostsEnabled =
      os_signpost_enabled([SmoothClipView signpostLog]);
  os_signpost_id_t identifier = OS_SIGNPOST_ID_NULL;
  if (signpostsEnabled) {
    identifier = os_signpost_id_generate([SmoothClipView signpostLog]);
    os_signpost_interval_begin(
        [SmoothClipView signpostLog], identifier, "canonicalization");
  }
#endif
  const BOOL valid = SmoothClipCanonicalizeGeometry(
      CGRectGetMinX(_requestedClip),
      CGRectGetMinY(_requestedClip),
      CGRectGetWidth(_requestedClip),
      CGRectGetHeight(_requestedClip),
      _requestedRadii.topLeft,
      _requestedRadii.topRight,
      _requestedRadii.bottomRight,
      _requestedRadii.bottomLeft,
      _requestedCurve,
      geometry);
#if defined(SMOOTH_CLIP_ENABLE_SIGNPOSTS) && SMOOTH_CLIP_ENABLE_SIGNPOSTS
  if (signpostsEnabled) {
    os_signpost_interval_end(
        [SmoothClipView signpostLog], identifier, "canonicalization");
  }
#endif
  return valid;
}

- (void)setClipContainerHidden:(BOOL)hidden {
  if (_clipHidden == hidden) return;
  _clipHidden = hidden;
  _clipContainer.hidden = hidden;
  _clipContainer.accessibilityElementsHidden = hidden;
}

- (void)syncVisibilityForRect:(CGRect)rect {
  [self setClipContainerHidden:CGRectIsEmpty(rect)];
  _clipContainer.accessibilityElementsHidden =
      !SmoothClipRotatedRectIntersectsHost(rect, self.bounds, _canonicalRotation) || _canonicalOpacity <= 0;
}

- (void)configureUnequalCornerMaskForGeometry:
    (SmoothClipCanonicalGeometry)geometry {
  _unequalCornerMask.bounds = geometry.rect;
  _unequalCornerMask.position = CGPointMake(
      CGRectGetMidX(geometry.rect), CGRectGetMidY(geometry.rect));
  CGPathRef path = SmoothClipCreateRoundedRectPath(
      geometry.rect, geometry.radii, geometry.curve);
  _unequalCornerMask.path = path;
  CGPathRelease(path);
}

- (void)applyStaticCornerRepresentation:
    (SmoothClipCanonicalGeometry)geometry {
  CALayer *layer = _clipContainer.layer;
  if (SmoothClipCornerRadiiAreUniform(geometry.radii)) {
    layer.mask = nil;
    layer.cornerRadius = geometry.radii.topLeft;
    layer.cornerCurve = SmoothClipCALayerCornerCurve(geometry.curve);
  } else {
    layer.cornerRadius = 0;
    layer.cornerCurve = kCACornerCurveCircular;
    [self configureUnequalCornerMaskForGeometry:geometry];
    layer.mask = _unequalCornerMask;
  }
}

- (SmoothClipCanonicalGeometry)canonicalGeometryValue {
  return {
      .rect = _canonicalClip,
      .radius = _canonicalRadius,
      .radii = _canonicalRadii,
      .curve = _canonicalCurve,
  };
}

- (void)writeLayerGeometry:(SmoothClipCanonicalGeometry)geometry
         hasExplicitRadii:(BOOL)hasExplicitRadii {
  const BOOL rectChanged =
      !CGRectEqualToRect(_canonicalClip, geometry.rect);
  const BOOL radiiChanged =
      !SmoothClipCornerRadiiEqual(_canonicalRadii, geometry.radii);
  const BOOL curveChanged = _canonicalCurve != geometry.curve;
  const BOOL representationChanged =
      _canonicalHasExplicitRadii != hasExplicitRadii;
  _canonicalClip = geometry.rect;
  _canonicalRadius = geometry.radius;
  _canonicalRadii = geometry.radii;
  _canonicalCurve = geometry.curve;
  _canonicalHasExplicitRadii = hasExplicitRadii;
  if (!rectChanged && !radiiChanged && !curveChanged &&
      !representationChanged) {
    return;
  }

#if defined(SMOOTH_CLIP_ENABLE_SIGNPOSTS) && SMOOTH_CLIP_ENABLE_SIGNPOSTS
  const bool signpostsEnabled =
      os_signpost_enabled([SmoothClipView signpostLog]);
  os_signpost_id_t identifier = OS_SIGNPOST_ID_NULL;
  if (signpostsEnabled) {
    identifier = os_signpost_id_generate([SmoothClipView signpostLog]);
    os_signpost_interval_begin(
        [SmoothClipView signpostLog], identifier, "layer-application");
  }
#endif
  CALayer *layer = _clipContainer.layer;
  if (rectChanged) {
    layer.bounds = geometry.rect;
    layer.position = CGPointMake(
        CGRectGetMidX(geometry.rect), CGRectGetMidY(geometry.rect));
  }
  // The uniform common case stays on CALayer's compositor fast path and uses
  // the platform's exact continuous-corner implementation.
  [self applyStaticCornerRepresentation:geometry];
#if defined(SMOOTH_CLIP_ENABLE_SIGNPOSTS) && SMOOTH_CLIP_ENABLE_SIGNPOSTS
  if (signpostsEnabled) {
    os_signpost_interval_end(
        [SmoothClipView signpostLog], identifier, "layer-application");
  }
#endif
}

- (void)writeAppearanceRotation:(double)rotation opacity:(double)opacity rect:(CGRect)rect {
  CALayer *layer = _presentationContainer.layer;
  // A zero-angle group is identity regardless of pivot. Keep it stationary so
  // existing geometry-only streams do not also dirty the parent layer each frame.
  const CGPoint center = rotation == 0 ? CGPointZero :
      CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
  const CGRect bounds = (CGRect){center, self.bounds.size};
  if (!CGRectEqualToRect(layer.bounds, bounds)) layer.bounds = bounds;
  if (!CGPointEqualToPoint(layer.position, center)) layer.position = center;
  if (_canonicalRotation != rotation) layer.affineTransform = CGAffineTransformMakeRotation(rotation);
  if (_canonicalOpacity != opacity) layer.opacity = smoothclip::clamp01(opacity);
  _canonicalRotation = rotation;
  _canonicalOpacity = opacity;
}

// The installed run's progress along its own curve now, as its layers show
// it: `group`'s local time (its frozen offset while paused for inactivity),
// through the run's timing curve, or the spring Core Animation runs. NO when
// no run is installed on `layer`.
- (BOOL)installedRunProgress:(double *)progress
                     ofGroup:(CAAnimation *)group
                     onLayer:(CALayer *)layer {
  if (_activeAnimationId == 0 || group == nil) return NO;
  const double elapsed = group.speed == 0 ? group.timeOffset :
      std::clamp([layer convertTime:CACurrentMediaTime() fromLayer:nil] - group.beginTime,
                 0.0, group.duration);
  if (_activeAnimationKind == 1) {
    *progress = smoothclip::cubicBezier(_timingAnimation.controlPoint1X,
        _timingAnimation.controlPoint1Y, _timingAnimation.controlPoint2X,
        _timingAnimation.controlPoint2Y, group.duration > 0 ? elapsed / group.duration : 1);
  } else {
    *progress = SmoothClipCARotationProgress(elapsed, _springAnimation);
  }
  return YES;
}

// Matrix decomposition loses complete turns. Use the installed native trajectory
// to choose the equivalent visible angle, including after a paused spring resumes.
- (double)visibleRotation {
  CAAnimation *group =
      [_presentationContainer.layer animationForKey:@"smoothClip.appearance"];
  CALayer *visible = _presentationContainer.layer.presentationLayer;
  double progress;
  if (visible == nil ||
      ![self installedRunProgress:&progress
                          ofGroup:group
                          onLayer:_presentationContainer.layer]) {
    return _canonicalRotation;
  }
  const double expected = _animationFromRotation +
      (_animationToRotation - _animationFromRotation) * progress;
  // `transform`, as smoothClipCurrentPresentation reads the content.
  const CGAffineTransform matrix =
      CATransform3DGetAffineTransform(visible.transform);
  return smoothclip::unwrapRotation(std::atan2(matrix.b, matrix.a), expected);
}

// A run is on the layers (installed, or paused for inactivity). Between an
// install's id assignment and its addAnimation: there is none yet, and the
// presentation layers still hold the last committed frame, not the start
// the registry has just applied (a flight's way back, an explicit `from`).
- (BOOL)hasRunOnLayers {
  return _activeAnimationId != 0 &&
      [_clipContainer.layer animationForKey:@"smoothClip.geometry"] != nil;
}

- (double)visibleOpacity {
  CALayer *layer = [self hasRunOnLayers] ? _presentationContainer.layer.presentationLayer : nil;
  return smoothclip::clamp01(layer == nil ? _canonicalOpacity : layer.opacity);
}

- (void)writeContentTranslation:(CGPoint)translation
                           scale:(CGFloat)scale {
  if (CGPointEqualToPoint(_canonicalContentTranslation, translation) &&
      _canonicalContentScale == scale) {
    return;
  }
  _canonicalContentTranslation = translation;
  _canonicalContentScale = scale;
  _contentContainer.layer.affineTransform =
      SmoothClipContentTransform(scale, translation);
}

- (void)applyRequestedClip {
  SmoothClipCanonicalGeometry geometry;
  if (![self canonicalRequestedGeometry:&geometry]) return;

  const BOOL accessibilityHidden =
      !SmoothClipRotatedRectIntersectsHost(geometry.rect, self.bounds, _requestedRotation) || _requestedOpacity <= 0;
  const BOOL visibilityChanged =
      _clipHidden != CGRectIsEmpty(geometry.rect) ||
      _clipContainer.accessibilityElementsHidden != accessibilityHidden;
  if (CGRectEqualToRect(_canonicalClip, geometry.rect) &&
      SmoothClipCornerRadiiEqual(_canonicalRadii, geometry.radii) &&
      _canonicalCurve == geometry.curve &&
      _canonicalHasExplicitRadii == _requestedHasExplicitRadii &&
      CGPointEqualToPoint(
          _canonicalContentTranslation, _requestedContentTranslation) &&
      _canonicalContentScale == _requestedContentScale &&
      _canonicalRotation == _requestedRotation && _canonicalOpacity == _requestedOpacity &&
      SmoothBoxShadowEqual(_canonicalShadow, _requestedShadow) &&
      !visibilityChanged) {
    return;
  }
  const SmoothClipCanonicalGeometry previousGeometry = [self canonicalGeometryValue];
  [self writeLayerGeometry:geometry
         hasExplicitRadii:_requestedHasExplicitRadii];
  [self writeContentTranslation:_requestedContentTranslation
                           scale:_requestedContentScale];
  if (!CGRectEqualToRect(previousGeometry.rect, geometry.rect) ||
      !SmoothClipCornerRadiiEqual(previousGeometry.radii, geometry.radii) ||
      previousGeometry.curve != geometry.curve ||
      !SmoothBoxShadowEqual(_canonicalShadow, _requestedShadow)) {
    [self writeShadow:_requestedShadow geometry:geometry];
  }
  [self writeAppearanceRotation:_requestedRotation opacity:_requestedOpacity rect:geometry.rect];
  [self syncVisibilityForRect:geometry.rect];
}

- (void)recordInteractiveRect:(CGRect)rect
                        radii:(SmoothClipCornerRadii)radii
           contentTranslation:(CGPoint)contentTranslation
                 contentScale:(CGFloat)contentScale {
  // Identical-value dedupe and same-frame coalescing live in the shared
  // tracker; coalescing keeps a distinct re-record issued sub-frame after
  // the last one (e.g. a fused animateTo `from` seed at gesture release)
  // from exploding the inherited velocity.
  smoothclip::recordVelocitySample(
      _velocitySamples,
      SmoothClipVelocityChannels(
          rect, radii, contentTranslation, contentScale),
      CACurrentMediaTime());
}

- (CGFloat)inheritedVelocityToRect:(CGRect)target
                             radii:(SmoothClipCornerRadii)targetRadii
                contentTranslation:(CGPoint)targetContentTranslation
                      contentScale:(CGFloat)targetContentScale {
  return smoothclip::inheritedVelocity(
      _velocitySamples,
      SmoothClipVelocityChannels(
          target,
          targetRadii,
          targetContentTranslation,
          targetContentScale),
      CACurrentMediaTime());
}

- (double)smoothClipInheritedVelocityToPresentation:
    (smoothclip::Presentation)presentation {
  SmoothClipCanonicalGeometry target;
  const SmoothClipCornerRadii radii =
      SmoothClipPresentationRadii(presentation.clip);
  if (!SmoothClipCanonicalizeGeometry(
          presentation.clip.x,
          presentation.clip.y,
          presentation.clip.width,
          presentation.clip.height,
          radii.topLeft,
          radii.topRight,
          radii.bottomRight,
          radii.bottomLeft,
          SmoothClipPresentationCurve(presentation.clip),
          &target)) {
    return 0;
  }
  return [self inheritedVelocityToRect:target.rect
                                 radii:target.radii
                    contentTranslation:CGPointMake(
                        presentation.contentTranslateX,
                        presentation.contentTranslateY)
                          contentScale:presentation.contentScale];
}

- (void)smoothClipApplyPresentation:(smoothclip::Presentation)presentation {
  [self smoothClipApplyPresentation:presentation recordVelocitySample:YES];
}

- (void)smoothClipApplyPresentation:(smoothclip::Presentation)presentation
               recordVelocitySample:(BOOL)recordVelocitySample {
  [self stopLayerAnimationWithoutCallback];
  [self storeRequestedPresentation:presentation];
  [self applyRequestedClip];
  // Skipped for writes that are not interactive motion (a pending-run
  // cancel-to-target): they must not enter the 'inherit' history.
  if (recordVelocitySample && _hasLayout) {
    [self recordInteractiveRect:_canonicalClip
                          radii:_canonicalRadii
             contentTranslation:_canonicalContentTranslation
                   contentScale:_canonicalContentScale];
  }
}

- (smoothclip::Presentation)smoothClipCurrentPresentation {
  SmoothClipCornerRadii visibleRadii = _canonicalRadii;
  const BOOL running = [self hasRunOnLayers];
  const CGRect visibleRect = running
      ? [self presentationRectWithRadii:&visibleRadii]
      : _canonicalClip;
  CALayer *contentLayer = running
      ? (CALayer *)_contentContainer.layer.presentationLayer
      : _contentContainer.layer;
  if (contentLayer == nil) contentLayer = _contentContainer.layer;
  // `transform`, not `affineTransform`. While a run animates
  // `transform.scale` (which scales z too), a presentation layer's
  // `affineTransform` is not the animated matrix: XCTest read scale 1, the
  // target, where `transform` read 0.70. Reading it started every replacement
  // of a moving run with the content at the old target.
  const CGAffineTransform transform =
      CATransform3DGetAffineTransform(contentLayer.transform);
  const BOOL uniform = SmoothClipCornerRadiiAreUniform(visibleRadii);
  smoothclip::Geometry geometry{
      CGRectGetMinX(visibleRect),
      CGRectGetMinY(visibleRect),
      CGRectGetWidth(visibleRect),
      CGRectGetHeight(visibleRect),
      uniform ? visibleRadii.topLeft : 0};
  if (_canonicalHasExplicitRadii || !uniform) {
    geometry.topLeftRadius = visibleRadii.topLeft;
    geometry.topRightRadius = visibleRadii.topRight;
    geometry.bottomRightRadius = visibleRadii.bottomRight;
    geometry.bottomLeftRadius = visibleRadii.bottomLeft;
  }
  geometry.curve = _canonicalCurve == SmoothClipCornerCurveContinuous
      ? smoothclip::ClipCurve::Continuous
      : smoothclip::ClipCurve::Circular;
  const CGFloat contentScale = hypot(transform.a, transform.b);
  smoothclip::Shadow shadow = _canonicalShadow;
  CALayer *shadowLayer = running && _shadowLayer != nil
      ? (CALayer *)_shadowLayer.presentationLayer
      : _shadowLayer;
  if (shadowLayer == nil) return SmoothClipCanonicalSnapshot({
      geometry, transform.tx, transform.ty, contentScale, shadow,
      [self visibleRotation], [self visibleOpacity]});
  if (shadowLayer.contents != nil) {
    // A baked tile: colour, blur, offset and spread are not layer
    // properties (a run swaps tiles); the layer's opacity carries the alpha.
    // Mid-run, the tile layer's frame moves the offset and spread along the
    // run's curve; take them there, not at the target the model holds. The
    // colour and blur are the tile's categories and stay the target's.
    shadow.enabled = _canonicalShadow.enabled || shadowLayer.opacity > 0;
    shadow.alpha = shadowLayer.opacity;
    double progress;
    if (running &&
        [self installedRunProgress:&progress
                           ofGroup:[_clipContainer.layer
                                       animationForKey:@"smoothClip.geometry"]
                           onLayer:_clipContainer.layer]) {
      const auto mix = [progress](double from, double to) {
        return from + (to - from) * progress;
      };
      shadow.offsetX =
          mix(_animationFromShadow.offsetX, _animationToShadow.offsetX);
      shadow.offsetY =
          mix(_animationFromShadow.offsetY, _animationToShadow.offsetY);
      shadow.spreadDistance = mix(
          _animationFromShadow.spreadDistance,
          _animationToShadow.spreadDistance);
    }
    return SmoothClipCanonicalSnapshot({
        geometry, transform.tx, transform.ty, contentScale, shadow,
        [self visibleRotation], [self visibleOpacity]});
  }
  shadow.enabled = _canonicalShadow.enabled || shadowLayer.shadowOpacity > 0;
  shadow.blurRadius = shadowLayer.shadowRadius * 2.0;
  shadow.offsetX = shadowLayer.shadowOffset.width;
  shadow.offsetY = shadowLayer.shadowOffset.height;
  CGColorRef color = shadowLayer.shadowColor;
  if (color != nil) {
    UIColor *uiColor = [UIColor colorWithCGColor:color];
    CGFloat red = 0, green = 0, blue = 0, alpha = 0;
    if ([uiColor getRed:&red green:&green blue:&blue alpha:&alpha]) {
      shadow.red = red;
      shadow.green = green;
      shadow.blue = blue;
      shadow.alpha = alpha;
    }
  }
  CGPathRef shadowPath = shadowLayer.shadowPath;
  if (shadowPath != nil && !CGRectIsEmpty(visibleRect)) {
    const CGRect shadowBounds = CGPathGetBoundingBox(shadowPath);
    shadow.spreadDistance =
        CGRectGetMinX(visibleRect) - CGRectGetMinX(shadowBounds);
  }
  return SmoothClipCanonicalSnapshot(
      {geometry, transform.tx, transform.ty, contentScale, shadow,
      [self visibleRotation], [self visibleOpacity]});
}

- (BOOL)smoothClipIsJoinable {
  // A view without layout reports zero geometry from
  // smoothClipCurrentPresentation and must not be used as a join reference.
  return _hasLayout && self.bounds.size.width > 0 &&
      self.bounds.size.height > 0;
}

- (BOOL)smoothClipCanDisplay {
  // A CA animation committed while this view's layer tree is detached from
  // the render tree does not survive the later attach commit; installs and
  // pre-ready runs must wait until a frame can actually be produced.
  return [self smoothClipIsJoinable] &&
      // A lifted host displays in the flight layer, even once its own
      // screen detaches; an off-window flight host can lift into it.
      (self.window != nil || _flightCarrier.window != nil ||
       [self smoothClipCanEnterFlight]) &&
      smoothclip::applicationIsActive();
}

- (void)smoothClipClearVelocitySamples {
  smoothclip::clearVelocitySamples(_velocitySamples);
}

- (smoothclip::Presentation)smoothClipFreezePresentation {
  const smoothclip::Presentation visible =
      [self smoothClipCurrentPresentation];
  [self stopLayerAnimationWithoutCallback];
  [self storeRequestedPresentation:visible];
  [self applyRequestedClip];
  return visible;
}

- (CGRect)presentationRectWithRadii:(SmoothClipCornerRadii *)radii {
  CALayer *layer = (CALayer *)_clipContainer.layer.presentationLayer;
  if (layer == nil) layer = _clipContainer.layer;
  const CGRect bounds = layer.bounds;
  const CGPoint position = layer.position;
  const CGRect rect = CGRectMake(
      position.x - bounds.size.width * layer.anchorPoint.x,
      position.y - bounds.size.height * layer.anchorPoint.y,
      bounds.size.width,
      bounds.size.height);
  if (radii != nullptr) {
    if (_clipContainer.layer.mask == _unequalCornerMask) {
      CAShapeLayer *mask =
          (CAShapeLayer *)_unequalCornerMask.presentationLayer;
      if (mask == nil) mask = _unequalCornerMask;
      *radii = SmoothClipRadiiFromFixedPath(
          mask.path, rect, _canonicalRadii);
    } else {
      *radii = {
          layer.cornerRadius,
          layer.cornerRadius,
          layer.cornerRadius,
          layer.cornerRadius,
      };
    }
  }
  return rect;
}

- (void)stopLayerAnimationWithoutCallback {
  if (_activeAnimationId == 0) return;
  // Invalidate before removing: CA may deliver didStop for the removed
  // animation after this method returns, when _ignoreAnimationCallback has
  // already been reset — and the id-preserving reinstall paths reuse the
  // same animation id, so the id check alone cannot filter it.
  _animationDelegate.invalidated = YES;
  _ignoreAnimationCallback = YES;
  [_clipContainer.layer removeAnimationForKey:@"smoothClip.geometry"];
  [_contentContainer.layer removeAnimationForKey:@"smoothClip.content"];
  [_unequalCornerMask removeAnimationForKey:@"smoothClip.mask"];
  [_presentationContainer.layer removeAnimationForKey:@"smoothClip.appearance"];
  [_shadowLayer removeAnimationForKey:@"smoothClip.shadow"];
  if (_hasMaskAnimation) {
    [self applyStaticCornerRepresentation:[self canonicalGeometryValue]];
  }
  _ignoreAnimationCallback = NO;
  _activeAnimationId = 0;
  _activeAnimationKind = 0;
  _animationDelegate = nil;
  _springPausedForInactivity = NO;
  _pausedSpringHadMaskAnimation = NO;
  _pausedSpringHadShadowAnimation = NO;
}

- (CABasicAnimation *)basicAnimationForKeyPath:(NSString *)keyPath
                                     fromValue:(id)fromValue
                                       toValue:(id)toValue
                                timingFunction:(CAMediaTimingFunction *)timing {
  CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:keyPath];
  animation.fromValue = fromValue;
  animation.toValue = toValue;
  animation.timingFunction = timing;
  return animation;
}

- (CFTimeInterval)springSettlingDurationWithVelocity:(double)velocity {
  // Every key path shares one normalized trajectory. Derive the terminal
  // duration from the same relative-energy rule as Android/Reanimated instead
  // of asking each Core Animation property for an independent settle time.
  return smoothclip::springSettleDuration(_springAnimation, velocity);
}

- (CASpringAnimation *)springAnimationForKeyPath:(NSString *)keyPath
                                        fromValue:(id)fromValue
                                          toValue:(id)toValue
                                         velocity:(double)velocity
                                         duration:(CFTimeInterval)duration {
  CASpringAnimation *animation =
      [CASpringAnimation animationWithKeyPath:keyPath];
  animation.fromValue = fromValue;
  animation.toValue = toValue;
  animation.mass = _springAnimation.mass;
  animation.stiffness = _springAnimation.stiffness;
  animation.damping = _springAnimation.damping;
  animation.initialVelocity = velocity;
  animation.duration = duration;
  return animation;
}

- (void)installAnimationFromGeometry:
            (SmoothClipCanonicalGeometry)fromGeometry
                   fromContentTranslation:(CGPoint)fromContentTranslation
                         fromContentScale:(CGFloat)fromContentScale
                              fromShadow:(smoothclip::Shadow)fromShadow
                            fromRotation:(double)fromRotation
                             fromOpacity:(double)fromOpacity
                               toGeometry:
            (SmoothClipCanonicalGeometry)toGeometry
                     hasExplicitToRadii:(BOOL)hasExplicitToRadii
                     toContentTranslation:(CGPoint)toContentTranslation
                           toContentScale:(CGFloat)toContentScale
                                toShadow:(smoothclip::Shadow)toShadow
                              toRotation:(double)toRotation
                               toOpacity:(double)toOpacity
                                 duration:(CFTimeInterval)duration
                            sharedBeginTime:(CFTimeInterval)sharedBeginTime {
  const int32_t animationId = _activeAnimationId;
  const NSInteger animationKind = _activeAnimationKind;
  [self stopLayerAnimationWithoutCallback];
  _activeAnimationId = animationId;
  _activeAnimationKind = animationKind;
  // Unhide while any animated frame can show content; an empty-to-empty
  // transition must stay hidden for accessibility.
  if (!CGRectIsEmpty(toGeometry.rect) ||
      !CGRectIsEmpty(fromGeometry.rect)) {
    [self setClipContainerHidden:NO];
  }
  // Autonomous native motion has no per-frame accessibility layout updates.
  // Hide moving descendants until the endpoint is committed.
  _clipContainer.accessibilityElementsHidden = YES;

  CALayer *layer = _clipContainer.layer;
  const CGRect toBounds = toGeometry.rect;
  const CGPoint fromPosition =
      CGPointMake(
          CGRectGetMidX(fromGeometry.rect),
          CGRectGetMidY(fromGeometry.rect));
  const CGPoint toPosition =
      CGPointMake(
          CGRectGetMidX(toGeometry.rect),
          CGRectGetMidY(toGeometry.rect));
  const BOOL changesShape = !CGRectEqualToRect(fromGeometry.rect, toGeometry.rect) ||
      !SmoothClipCornerRadiiEqual(fromGeometry.radii, toGeometry.radii) ||
      fromGeometry.curve != toGeometry.curve;
  const BOOL usesMask = changesShape &&
      (!SmoothClipCornerRadiiAreUniform(fromGeometry.radii) ||
       !SmoothClipCornerRadiiAreUniform(toGeometry.radii) ||
       fromGeometry.curve != toGeometry.curve);
  [self writeLayerGeometry:toGeometry
         hasExplicitRadii:hasExplicitToRadii];
  [self writeContentTranslation:toContentTranslation scale:toContentScale];
  [self writeAppearanceRotation:toRotation opacity:toOpacity rect:toGeometry.rect];
  _animationFromRotation = fromRotation;
  _animationToRotation = toRotation;
  _canonicalShadow = toShadow;
  SmoothBoxShadowNormalizeAnimationEndpoints(
      fromGeometry, &fromShadow, toGeometry, &toShadow);
  _animationFromShadow = fromShadow;
  _animationToShadow = toShadow;
  // A baked run animates the tile layer's frame and opacity and swaps tiles
  // in steps (bakedShadowAnimationsFromGeometry:...). One non-uniform
  // endpoint has no tile, so such a run takes the blur path throughout.
  const BOOL bakedShadow =
      (SmoothBoxShadowVisible(fromGeometry, fromShadow) ||
       SmoothBoxShadowVisible(toGeometry, toShadow)) &&
      [self usesBakedShadowForGeometry:fromGeometry shadow:fromShadow] &&
      [self usesBakedShadowForGeometry:toGeometry shadow:toShadow];
  // The target model layer is complete before any presentation animations are
  // attached. Core Animation may remove the terminal presentation animation
  // before its delegate runs, so correctness cannot depend on completion-time
  // cleanup hiding a stale path or opaque color.
  [self writeShadowModel:toShadow
                geometry:toGeometry
                   baked:bakedShadow
             nearestTile:NO];
  if (usesMask) {
    // Keep one mask representation for the full interval, including an
    // unequal→uniform transition. Switching layer.mask mid-animation would
    // create a one-frame seam even though the underlying paths are compatible.
    [self configureUnequalCornerMaskForGeometry:toGeometry];
    layer.cornerRadius = 0;
    layer.mask = _unequalCornerMask;
  }

  CGPathRef fromMaskPath = usesMask
      ? SmoothClipCreateRoundedRectPath(
            fromGeometry.rect, fromGeometry.radii, fromGeometry.curve)
      : nil;
  CGPathRef toMaskPath = usesMask
      ? SmoothClipCreateRoundedRectPath(
            toGeometry.rect, toGeometry.radii, toGeometry.curve)
      : nil;
  const BOOL fromShadowVisible =
      SmoothBoxShadowVisible(fromGeometry, fromShadow);
  const BOOL toShadowVisible =
      SmoothBoxShadowVisible(toGeometry, toShadow);
  const BOOL hasVisibleShadow = fromShadowVisible || toShadowVisible;
  const BOOL animatesShadowPath = hasVisibleShadow &&
      !SmoothBoxShadowPathInputEqual(
          fromGeometry, fromShadow, toGeometry, toShadow);
  const BOOL animatesShadowColor = hasVisibleShadow &&
      !SmoothBoxShadowColorEqual(fromShadow, toShadow);
  const BOOL animatesShadowRadius = hasVisibleShadow &&
      fromShadow.blurRadius != toShadow.blurRadius;
  const BOOL animatesShadowOffset = hasVisibleShadow &&
      (fromShadow.offsetX != toShadow.offsetX ||
       fromShadow.offsetY != toShadow.offsetY);
  const BOOL animatesShadow = animatesShadowPath || animatesShadowColor ||
      animatesShadowRadius || animatesShadowOffset;
  if (hasVisibleShadow) {
    [self ensureShadowLayer];
    // Reveal opacity is encoded in shadowColor alpha. Animating layer opacity
    // too would multiply both curves and produce a quadratic-looking fade.
    // (A baked tile has no shadowColor; its alpha is the layer opacity.)
    if (!bakedShadow) _shadowLayer.shadowOpacity = 1;
  }
  CGPathRef fromShadowPath = animatesShadowPath && !bakedShadow
      ? SmoothClipCreateShadowPath(fromGeometry, fromShadow)
      : nil;
  CGPathRef toShadowPath = animatesShadowPath && !bakedShadow
      ? SmoothClipCreateShadowPath(toGeometry, toShadow)
      : nil;
  CAAnimationGroup *group = [CAAnimationGroup animation];
  CAAnimationGroup *contentGroup = [CAAnimationGroup animation];
  CAAnimationGroup *shadowGroup = animatesShadow
      ? [CAAnimationGroup animation]
      : nil;
  CAAnimationGroup *maskAnimation = nil;
  _hasMaskAnimation = usesMask;
  if (_activeAnimationKind == 1) {
    CAMediaTimingFunction *timing = [CAMediaTimingFunction
        functionWithControlPoints:_timingAnimation.controlPoint1X
                                  :_timingAnimation.controlPoint1Y
                                  :_timingAnimation.controlPoint2X
                                  :_timingAnimation.controlPoint2Y];
    NSMutableArray<CAAnimation *> *geometryAnimations = [NSMutableArray arrayWithArray:@[
      [self basicAnimationForKeyPath:@"bounds"
                           fromValue:[NSValue valueWithCGRect:fromGeometry.rect]
                             toValue:[NSValue valueWithCGRect:toBounds]
                      timingFunction:timing],
      [self basicAnimationForKeyPath:@"position"
                           fromValue:[NSValue valueWithCGPoint:fromPosition]
                             toValue:[NSValue valueWithCGPoint:toPosition]
                      timingFunction:timing],
    ]];
    if (usesMask) {
      maskAnimation = [CAAnimationGroup animation];
      maskAnimation.animations = @[
        [self basicAnimationForKeyPath:@"path"
                             fromValue:(__bridge id)fromMaskPath
                               toValue:(__bridge id)toMaskPath
                        timingFunction:timing],
        [self basicAnimationForKeyPath:@"bounds"
                             fromValue:[NSValue valueWithCGRect:fromGeometry.rect]
                               toValue:[NSValue valueWithCGRect:toGeometry.rect]
                        timingFunction:timing],
        [self basicAnimationForKeyPath:@"position"
                             fromValue:[NSValue valueWithCGPoint:fromPosition]
                               toValue:[NSValue valueWithCGPoint:toPosition]
                        timingFunction:timing],
      ];
    } else {
      [geometryAnimations addObject:
          [self basicAnimationForKeyPath:@"cornerRadius"
                               fromValue:@(fromGeometry.radii.topLeft)
                                 toValue:@(toGeometry.radii.topLeft)
                          timingFunction:timing]];
    }
    group.animations = geometryAnimations;
    group.duration = duration;
    NSMutableArray<CAAnimation *> *contentAnimations = [NSMutableArray arrayWithArray:@[
      [self basicAnimationForKeyPath:@"transform.translation.x"
                           fromValue:@(fromContentTranslation.x)
                             toValue:@(toContentTranslation.x)
                      timingFunction:timing],
      [self basicAnimationForKeyPath:@"transform.translation.y"
                           fromValue:@(fromContentTranslation.y)
                             toValue:@(toContentTranslation.y)
                      timingFunction:timing],
    ]];
    if (fromContentScale != 1 || toContentScale != 1) {
      [contentAnimations addObject:
          [self basicAnimationForKeyPath:@"transform.scale"
                               fromValue:@(fromContentScale)
                                 toValue:@(toContentScale)
                          timingFunction:timing]];
    }
    contentGroup.animations = contentAnimations;
    contentGroup.duration = duration;
    if (animatesShadow && bakedShadow) {
      shadowGroup.animations = [self
          bakedShadowAnimationsFromGeometry:fromGeometry
                                 fromShadow:fromShadow
                                 toGeometry:toGeometry
                                   toShadow:toShadow
                                     timing:timing
                                     spring:NO
                                   velocity:0
                                   duration:duration];
      shadowGroup.duration = duration;
    } else if (animatesShadow) {
      NSMutableArray<CAAnimation *> *shadowAnimations = [NSMutableArray array];
      if (animatesShadowPath) [shadowAnimations addObject:
          [self basicAnimationForKeyPath:@"shadowPath"
                           fromValue:(__bridge id)fromShadowPath
                             toValue:(__bridge id)toShadowPath
                      timingFunction:timing]];
      if (animatesShadowColor) [shadowAnimations addObject:
          [self basicAnimationForKeyPath:@"shadowColor"
                           fromValue:(__bridge id)[self colorForShadow:fromShadow]
                             toValue:(__bridge id)[self colorForShadow:toShadow]
                      timingFunction:timing]];
      if (animatesShadowRadius) [shadowAnimations addObject:
          [self basicAnimationForKeyPath:@"shadowRadius"
                           fromValue:@(MAX(0, fromShadow.blurRadius) / 2.0)
                             toValue:@(MAX(0, toShadow.blurRadius) / 2.0)
                      timingFunction:timing]];
      if (animatesShadowOffset) [shadowAnimations addObject:
          [self basicAnimationForKeyPath:@"shadowOffset"
                           fromValue:[NSValue valueWithCGSize:CGSizeMake(
                               fromShadow.offsetX, fromShadow.offsetY)]
                             toValue:[NSValue valueWithCGSize:CGSizeMake(
                               toShadow.offsetX, toShadow.offsetY)]
                      timingFunction:timing]];
      shadowGroup.animations = shadowAnimations;
      shadowGroup.duration = duration;
    }
  } else {
    // `_springAnimation.initialVelocity` is the interactive motion projected
    // onto the current-to-target trajectory, normalized by that distance
    // (units 1/s). CASpringAnimation.initialVelocity uses the same normalized
    // convention — its settlingDuration is independent of the from/to
    // distance — so every key path receives the scalar unchanged. Multiplying
    // by per-property deltas would overstate the launch velocity by the pixel
    // distance and blow out the settling time.
    const double velocity = _springAnimation.initialVelocity;
    const CFTimeInterval springDuration =
        [self springSettlingDurationWithVelocity:velocity];
    NSMutableArray<CAAnimation *> *geometryAnimations = [NSMutableArray arrayWithArray:@[
      [self springAnimationForKeyPath:@"bounds.origin.x"
                            fromValue:@(fromGeometry.rect.origin.x)
                              toValue:@(toBounds.origin.x)
                             velocity:velocity
                             duration:springDuration],
      [self springAnimationForKeyPath:@"bounds.origin.y"
                            fromValue:@(fromGeometry.rect.origin.y)
                              toValue:@(toBounds.origin.y)
                             velocity:velocity
                             duration:springDuration],
      [self springAnimationForKeyPath:@"bounds.size.width"
                            fromValue:@(fromGeometry.rect.size.width)
                              toValue:@(toBounds.size.width)
                             velocity:velocity
                             duration:springDuration],
      [self springAnimationForKeyPath:@"bounds.size.height"
                            fromValue:@(fromGeometry.rect.size.height)
                              toValue:@(toBounds.size.height)
                             velocity:velocity
                             duration:springDuration],
      [self springAnimationForKeyPath:@"position.x"
                            fromValue:@(fromPosition.x)
                              toValue:@(toPosition.x)
                             velocity:velocity
                             duration:springDuration],
      [self springAnimationForKeyPath:@"position.y"
                            fromValue:@(fromPosition.y)
                              toValue:@(toPosition.y)
                             velocity:velocity
                             duration:springDuration],
    ]];
    if (usesMask) {
      maskAnimation = [CAAnimationGroup animation];
      maskAnimation.animations = @[
        [self springAnimationForKeyPath:@"path"
                              fromValue:(__bridge id)fromMaskPath
                                toValue:(__bridge id)toMaskPath
                               velocity:velocity
                               duration:springDuration],
        [self springAnimationForKeyPath:@"bounds.origin.x"
                              fromValue:@(fromGeometry.rect.origin.x)
                                toValue:@(toGeometry.rect.origin.x)
                               velocity:velocity
                               duration:springDuration],
        [self springAnimationForKeyPath:@"bounds.origin.y"
                              fromValue:@(fromGeometry.rect.origin.y)
                                toValue:@(toGeometry.rect.origin.y)
                               velocity:velocity
                               duration:springDuration],
        [self springAnimationForKeyPath:@"bounds.size.width"
                              fromValue:@(fromGeometry.rect.size.width)
                                toValue:@(toGeometry.rect.size.width)
                               velocity:velocity
                               duration:springDuration],
        [self springAnimationForKeyPath:@"bounds.size.height"
                              fromValue:@(fromGeometry.rect.size.height)
                                toValue:@(toGeometry.rect.size.height)
                               velocity:velocity
                               duration:springDuration],
        [self springAnimationForKeyPath:@"position.x"
                              fromValue:@(fromPosition.x)
                                toValue:@(toPosition.x)
                               velocity:velocity
                               duration:springDuration],
        [self springAnimationForKeyPath:@"position.y"
                              fromValue:@(fromPosition.y)
                                toValue:@(toPosition.y)
                               velocity:velocity
                               duration:springDuration],
      ];
    } else {
      [geometryAnimations addObject:
          [self springAnimationForKeyPath:@"cornerRadius"
                                fromValue:@(fromGeometry.radii.topLeft)
                                  toValue:@(toGeometry.radii.topLeft)
                                 velocity:velocity
                                 duration:springDuration]];
    }
    group.animations = geometryAnimations;
    // Springs use their analytic settling time; a wall-clock duration would
    // truncate oscillation and snap to the target.
    group.duration = springDuration;
    NSMutableArray<CAAnimation *> *contentAnimations = [NSMutableArray arrayWithArray:@[
      [self springAnimationForKeyPath:@"transform.translation.x"
                            fromValue:@(fromContentTranslation.x)
                              toValue:@(toContentTranslation.x)
                             velocity:velocity
                             duration:springDuration],
      [self springAnimationForKeyPath:@"transform.translation.y"
                            fromValue:@(fromContentTranslation.y)
                              toValue:@(toContentTranslation.y)
                             velocity:velocity
                             duration:springDuration],
    ]];
    if (fromContentScale != 1 || toContentScale != 1) {
      [contentAnimations addObject:
          [self springAnimationForKeyPath:@"transform.scale"
                                fromValue:@(fromContentScale)
                                  toValue:@(toContentScale)
                                 velocity:velocity
                                 duration:springDuration]];
    }
    contentGroup.animations = contentAnimations;
    contentGroup.duration = springDuration;
    if (animatesShadow && bakedShadow) {
      shadowGroup.animations = [self
          bakedShadowAnimationsFromGeometry:fromGeometry
                                 fromShadow:fromShadow
                                 toGeometry:toGeometry
                                   toShadow:toShadow
                                     timing:nil
                                     spring:YES
                                   velocity:velocity
                                   duration:springDuration];
      shadowGroup.duration = springDuration;
    } else if (animatesShadow) {
      NSMutableArray<CAAnimation *> *shadowAnimations = [NSMutableArray array];
      if (animatesShadowPath) [shadowAnimations addObject:
          [self springAnimationForKeyPath:@"shadowPath"
                            fromValue:(__bridge id)fromShadowPath
                              toValue:(__bridge id)toShadowPath
                             velocity:velocity
                             duration:springDuration]];
      if (animatesShadowColor) [shadowAnimations addObject:
          [self springAnimationForKeyPath:@"shadowColor"
                            fromValue:(__bridge id)[self colorForShadow:fromShadow]
                              toValue:(__bridge id)[self colorForShadow:toShadow]
                             velocity:velocity
                             duration:springDuration]];
      if (animatesShadowRadius) [shadowAnimations addObject:
          [self springAnimationForKeyPath:@"shadowRadius"
                            fromValue:@(MAX(0, fromShadow.blurRadius) / 2.0)
                              toValue:@(MAX(0, toShadow.blurRadius) / 2.0)
                             velocity:velocity
                             duration:springDuration]];
      if (animatesShadowOffset) [shadowAnimations addObject:
          [self springAnimationForKeyPath:@"shadowOffset"
                            fromValue:[NSValue valueWithCGSize:CGSizeMake(
                                fromShadow.offsetX, fromShadow.offsetY)]
                              toValue:[NSValue valueWithCGSize:CGSizeMake(
                                toShadow.offsetX, toShadow.offsetY)]
                             velocity:velocity
                             duration:springDuration]];
      shadowGroup.animations = shadowAnimations;
      shadowGroup.duration = springDuration;
    }
  }

  if (maskAnimation != nil) {
    maskAnimation.duration = group.duration;
  }

  CAAnimationGroup *appearanceGroup = [CAAnimationGroup animation];
  NSMutableArray<CAAnimation *> *appearanceAnimations = [NSMutableArray array];
  // A zero anchor and moving bounds origin avoid host-size-dependent pivot math.
  NSArray<NSString *> *keys = @[@"bounds.origin.x", @"bounds.origin.y", @"position.x",
      @"position.y", @"transform.rotation.z", @"opacity"];
  NSArray<NSNumber *> *fromValues = @[@(fromPosition.x), @(fromPosition.y), @(fromPosition.x),
      @(fromPosition.y), @(fromRotation), @(fromOpacity)];
  NSArray<NSNumber *> *toValues = @[@(toPosition.x), @(toPosition.y), @(toPosition.x),
      @(toPosition.y), @(toRotation), @(toOpacity)];
  for (NSUInteger index = 0; index < keys.count; index++) {
    if ([fromValues[index] isEqual:toValues[index]]) continue;
    // At zero rotation, origin/position cancel exactly; no pivot animation is needed.
    if (index < 4 && fromRotation == 0 && toRotation == 0) continue;
    CAAnimation *animation;
    if (_activeAnimationKind == 1) {
      CAMediaTimingFunction *timing = [CAMediaTimingFunction
          functionWithControlPoints:_timingAnimation.controlPoint1X :_timingAnimation.controlPoint1Y
          :_timingAnimation.controlPoint2X :_timingAnimation.controlPoint2Y];
      animation = [self basicAnimationForKeyPath:keys[index] fromValue:fromValues[index]
          toValue:toValues[index] timingFunction:timing];
    } else {
      animation = [self springAnimationForKeyPath:keys[index] fromValue:fromValues[index]
          toValue:toValues[index] velocity:_springAnimation.initialVelocity duration:group.duration];
    }
    [appearanceAnimations addObject:animation];
  }
  appearanceGroup.animations = appearanceAnimations;
  appearanceGroup.duration = group.duration;


  // An explicit media-time origin is required to pause and resume spring
  // groups without touching the parent layer clock (which would also pause
  // consumer animations in the clipped subtree).
  if (sharedBeginTime <= 0) {
    sharedBeginTime = CACurrentMediaTime();
  }
  if (sharedBeginTime > 0) {
    // Each layer receives the same absolute media timestamp translated into
    // its local clock. Group participants therefore advance from one epoch
    // even though their animations are installed sequentially.
    appearanceGroup.beginTime = [_presentationContainer.layer convertTime:sharedBeginTime fromLayer:nil];
    group.beginTime = [layer convertTime:sharedBeginTime fromLayer:nil];
    contentGroup.beginTime = [_contentContainer.layer
        convertTime:sharedBeginTime
        fromLayer:nil];
    if (animatesShadow) {
      shadowGroup.beginTime = [_shadowLayer
          convertTime:sharedBeginTime
          fromLayer:nil];
    }
    if (maskAnimation != nil) {
      maskAnimation.beginTime = [_unequalCornerMask
          convertTime:sharedBeginTime
          fromLayer:nil];
    }
  }

  _animationDelegate = [SmoothClipAnimationDelegate new];
  _animationDelegate.view = self;
  _animationDelegate.driverId = _driverId;
  _animationDelegate.animationId = _activeAnimationId;
  group.delegate = _animationDelegate;
  _springPausedForInactivity = NO;
  _pausedSpringHadMaskAnimation = NO;
  _pausedSpringHadShadowAnimation = NO;
  _hasAppearanceAnimation = appearanceAnimations.count > 0;
  if (_hasAppearanceAnimation) {
    [_presentationContainer.layer addAnimation:appearanceGroup forKey:@"smoothClip.appearance"];
  }
  HERO_TRACE("clip-install driver=%llu begin=%.6f duration=%.3f", _driverId, sharedBeginTime, group.duration);
  [layer addAnimation:group forKey:@"smoothClip.geometry"];
  [_contentContainer.layer addAnimation:contentGroup
                                 forKey:@"smoothClip.content"];
  if (animatesShadow) {
    [_shadowLayer addAnimation:shadowGroup forKey:@"smoothClip.shadow"];
  }
  if (maskAnimation != nil) {
    [_unequalCornerMask addAnimation:maskAnimation forKey:@"smoothClip.mask"];
  }
  if (fromMaskPath != nil) CGPathRelease(fromMaskPath);
  if (toMaskPath != nil) CGPathRelease(toMaskPath);
  if (fromShadowPath != nil) CGPathRelease(fromShadowPath);
  if (toShadowPath != nil) CGPathRelease(toShadowPath);
}

- (BOOL)startAnimationToRequestedGeometryWithDuration:(CFTimeInterval)duration
                                       sharedBeginTime:
                                           (CFTimeInterval)sharedBeginTime {
  if (![self smoothClipCanDisplay]) {
    return NO;
  }
  SmoothClipCanonicalGeometry target;
  if (![self canonicalRequestedGeometry:&target]) return NO;
  const smoothclip::Presentation current = [self smoothClipCurrentPresentation];
  const SmoothClipCornerRadii currentRadii =
      SmoothClipPresentationRadii(current.clip);
  const SmoothClipCanonicalGeometry fromGeometry = {
      .rect = CGRectMake(
          current.clip.x,
          current.clip.y,
          current.clip.width,
          current.clip.height),
      .radius = SmoothClipCornerRadiiAreUniform(currentRadii)
          ? currentRadii.topLeft
          : 0,
      .radii = currentRadii,
      .curve = SmoothClipPresentationCurve(current.clip),
  };
  [self installAnimationFromGeometry:fromGeometry
              fromContentTranslation:CGPointMake(
                                         current.contentTranslateX,
                                         current.contentTranslateY)
                    fromContentScale:current.contentScale
                         fromShadow:current.shadow
                       fromRotation:current.rotation
                        fromOpacity:current.opacity
                          toGeometry:target
                hasExplicitToRadii:_requestedHasExplicitRadii
                toContentTranslation:_requestedContentTranslation
                      toContentScale:_requestedContentScale
                           toShadow:_requestedShadow
                         toRotation:_requestedRotation
                          toOpacity:_requestedOpacity
                            duration:duration
                     sharedBeginTime:sharedBeginTime];
  return YES;
}

- (BOOL)smoothClipAnimateTiming:(smoothclip::Presentation)presentation
                       animation:(smoothclip::TimingAnimation)animation
                     animationId:(int32_t)animationId {
  return [self smoothClipAnimateTiming:presentation
                              animation:animation
                            animationId:animationId
                        sharedBeginTime:0];
}

- (BOOL)smoothClipAnimateTiming:(smoothclip::Presentation)presentation
                       animation:(smoothclip::TimingAnimation)animation
                     animationId:(int32_t)animationId
                 sharedBeginTime:(CFTimeInterval)sharedBeginTime {
  [self storeRequestedPresentation:presentation];
  _timingAnimation = animation;
  _activeAnimationKind = 1;
  _activeAnimationId = animationId;
  return [self startAnimationToRequestedGeometryWithDuration:
                   MAX(0, animation.durationMs) / 1000.0
                                         sharedBeginTime:sharedBeginTime];
}

- (BOOL)smoothClipAnimateSpring:(smoothclip::Presentation)presentation
                       animation:(smoothclip::SpringAnimation)animation
                     animationId:(int32_t)animationId {
  return [self smoothClipAnimateSpring:presentation
                              animation:animation
                            animationId:animationId
                        sharedBeginTime:0];
}

- (BOOL)smoothClipAnimateSpring:(smoothclip::Presentation)presentation
                       animation:(smoothclip::SpringAnimation)animation
                     animationId:(int32_t)animationId
                 sharedBeginTime:(CFTimeInterval)sharedBeginTime {
  [self storeRequestedPresentation:presentation];
  _springAnimation = animation;
  if (animation.inheritVelocity) {
    SmoothClipCanonicalGeometry target;
    if ([self canonicalRequestedGeometry:&target]) {
      _springAnimation.initialVelocity =
          [self inheritedVelocityToRect:target.rect
                                   radii:target.radii
                      contentTranslation:_requestedContentTranslation
                            contentScale:_requestedContentScale];
    } else {
      _springAnimation.initialVelocity = 0;
    }
  }
  _activeAnimationKind = 2;
  _activeAnimationId = animationId;
  return [self startAnimationToRequestedGeometryWithDuration:0
                                              sharedBeginTime:sharedBeginTime];
}

- (void)smoothClipCancelAnimationUsingTarget:(BOOL)useTarget {
  if (_activeAnimationId == 0) return;
  const smoothclip::Presentation visible =
      [self smoothClipCurrentPresentation];
  [self stopLayerAnimationWithoutCallback];
  if (useTarget) {
    [self applyRequestedClip];
  } else {
    [self storeRequestedPresentation:visible];
    [self applyRequestedClip];
  }
}

- (BOOL)smoothClipPauseSpringAnimation:(int32_t)animationId
                           atMediaTime:(CFTimeInterval)mediaTime {
  if (_activeAnimationId != animationId || _activeAnimationKind != 2 ||
      _springPausedForInactivity) {
    return NO;
  }

  CALayer *geometryLayer = _clipContainer.layer;
  CALayer *contentLayer = _contentContainer.layer;
  CAAnimation *installedGeometry =
      [geometryLayer animationForKey:@"smoothClip.geometry"];
  CAAnimation *installedContent =
      [contentLayer animationForKey:@"smoothClip.content"];
  CAAnimation *installedAppearance = [_presentationContainer.layer animationForKey:@"smoothClip.appearance"];
  if ((_hasAppearanceAnimation && installedAppearance == nil) || installedGeometry == nil || installedContent == nil) return NO;

  auto pausedCopy = ^CAAnimation *(CALayer *layer, CAAnimation *installed) {
    if (installed == nil) return (CAAnimation *)nil;
    CAAnimation *paused = [installed copy];
    const CFTimeInterval localNow =
        [layer convertTime:mediaTime fromLayer:nil];
    const CFTimeInterval elapsed = std::clamp(
        localNow - installed.beginTime,
        (CFTimeInterval)0,
        installed.duration);
    paused.speed = 0;
    paused.timeOffset = elapsed;
    paused.beginTime = 0;
    return paused;
  };

  CAAnimation *appearance = pausedCopy(_presentationContainer.layer, installedAppearance);
  CAAnimation *geometry = pausedCopy(geometryLayer, installedGeometry);
  CAAnimation *content = pausedCopy(contentLayer, installedContent);
  CAAnimation *installedMask =
      [_unequalCornerMask animationForKey:@"smoothClip.mask"];
  CAAnimation *mask = pausedCopy(_unequalCornerMask, installedMask);
  CAAnimation *installedShadow =
      [_shadowLayer animationForKey:@"smoothClip.shadow"];
  CAAnimation *shadow = pausedCopy(_shadowLayer, installedShadow);

  _animationDelegate.invalidated = YES;
  _ignoreAnimationCallback = YES;
  [geometryLayer removeAnimationForKey:@"smoothClip.geometry"];
  [contentLayer removeAnimationForKey:@"smoothClip.content"];
  [_unequalCornerMask removeAnimationForKey:@"smoothClip.mask"];
  [_presentationContainer.layer removeAnimationForKey:@"smoothClip.appearance"];
  [_shadowLayer removeAnimationForKey:@"smoothClip.shadow"];

  _animationDelegate = [SmoothClipAnimationDelegate new];
  _animationDelegate.view = self;
  _animationDelegate.driverId = _driverId;
  _animationDelegate.animationId = animationId;
  geometry.delegate = _animationDelegate;
  if (appearance != nil) {
    [_presentationContainer.layer addAnimation:appearance forKey:@"smoothClip.appearance"];
  }
  [geometryLayer addAnimation:geometry forKey:@"smoothClip.geometry"];
  [contentLayer addAnimation:content forKey:@"smoothClip.content"];
  if (mask != nil) {
    [_unequalCornerMask addAnimation:mask forKey:@"smoothClip.mask"];
  }
  if (shadow != nil) {
    [_shadowLayer addAnimation:shadow forKey:@"smoothClip.shadow"];
  }
  _ignoreAnimationCallback = NO;
  _springPausedForInactivity = YES;
  _pausedSpringHadMaskAnimation = mask != nil;
  _pausedSpringHadShadowAnimation = shadow != nil;
  return YES;
}

- (BOOL)smoothClipResumeSpringAnimation:(int32_t)animationId
                            atMediaTime:(CFTimeInterval)mediaTime
                             catchUpBy:(CFTimeInterval)catchUp {
  if (_activeAnimationId != animationId || _activeAnimationKind != 2 ||
      !_springPausedForInactivity) {
    return NO;
  }

  CALayer *geometryLayer = _clipContainer.layer;
  CALayer *contentLayer = _contentContainer.layer;
  CAAnimation *installedGeometry =
      [geometryLayer animationForKey:@"smoothClip.geometry"];
  CAAnimation *installedContent =
      [contentLayer animationForKey:@"smoothClip.content"];
  CAAnimation *installedMask =
      [_unequalCornerMask animationForKey:@"smoothClip.mask"];
  CAAnimation *installedShadow =
      [_shadowLayer animationForKey:@"smoothClip.shadow"];
  CAAnimation *installedAppearance = [_presentationContainer.layer animationForKey:@"smoothClip.appearance"];
  if ((_hasAppearanceAnimation && installedAppearance == nil) || installedGeometry == nil || installedContent == nil ||
      (_pausedSpringHadMaskAnimation && installedMask == nil) ||
      (_pausedSpringHadShadowAnimation && installedShadow == nil)) {
    return NO;
  }

  auto resumedCopy = ^CAAnimation *(CALayer *layer, CAAnimation *installed) {
    if (installed == nil) return (CAAnimation *)nil;
    CAAnimation *resumed = [installed copy];
    const CFTimeInterval localNow =
        [layer convertTime:mediaTime fromLayer:nil];
    const CFTimeInterval resumedTime = std::min(
        installed.duration,
        std::max((CFTimeInterval)0, installed.timeOffset + catchUp));
    resumed.speed = 1;
    resumed.timeOffset = 0;
    resumed.beginTime = localNow - resumedTime;
    return resumed;
  };

  CAAnimation *appearance = resumedCopy(_presentationContainer.layer, installedAppearance);
  CAAnimation *geometry = resumedCopy(geometryLayer, installedGeometry);
  CAAnimation *content = resumedCopy(contentLayer, installedContent);
  CAAnimation *mask = resumedCopy(_unequalCornerMask, installedMask);
  CAAnimation *shadow = resumedCopy(_shadowLayer, installedShadow);

  _animationDelegate.invalidated = YES;
  _ignoreAnimationCallback = YES;
  [geometryLayer removeAnimationForKey:@"smoothClip.geometry"];
  [contentLayer removeAnimationForKey:@"smoothClip.content"];
  [_unequalCornerMask removeAnimationForKey:@"smoothClip.mask"];
  [_presentationContainer.layer removeAnimationForKey:@"smoothClip.appearance"];
  [_shadowLayer removeAnimationForKey:@"smoothClip.shadow"];

  _animationDelegate = [SmoothClipAnimationDelegate new];
  _animationDelegate.view = self;
  _animationDelegate.driverId = _driverId;
  _animationDelegate.animationId = animationId;
  geometry.delegate = _animationDelegate;
  if (appearance != nil) {
    [_presentationContainer.layer addAnimation:appearance forKey:@"smoothClip.appearance"];
  }
  [geometryLayer addAnimation:geometry forKey:@"smoothClip.geometry"];
  [contentLayer addAnimation:content forKey:@"smoothClip.content"];
  if (mask != nil) {
    [_unequalCornerMask addAnimation:mask forKey:@"smoothClip.mask"];
  }
  if (shadow != nil) {
    [_shadowLayer addAnimation:shadow forKey:@"smoothClip.shadow"];
  }
  _ignoreAnimationCallback = NO;
  _springPausedForInactivity = NO;
  _pausedSpringHadMaskAnimation = NO;
  _pausedSpringHadShadowAnimation = NO;
  return YES;
}

- (BOOL)smoothClipHasInstalledAnimation:(int32_t)animationId {
  return _activeAnimationId == animationId &&
      (!_hasAppearanceAnimation ||
       [_presentationContainer.layer animationForKey:@"smoothClip.appearance"] != nil) &&
      [_clipContainer.layer animationForKey:@"smoothClip.geometry"] != nil &&
      [_contentContainer.layer animationForKey:@"smoothClip.content"] != nil &&
      (!_springPausedForInactivity ||
       (!_pausedSpringHadMaskAnimation ||
        [_unequalCornerMask animationForKey:@"smoothClip.mask"] != nil)) &&
      (!_springPausedForInactivity ||
       (!_pausedSpringHadShadowAnimation ||
        [_shadowLayer animationForKey:@"smoothClip.shadow"] != nil));
}

- (void)smoothClipAnimationDidStopWithDriverId:(uint64_t)driverId
                                    animationId:(int32_t)animationId
                                       finished:(BOOL)finished {
  if (_ignoreAnimationCallback || animationId != _activeAnimationId) return;
  _activeAnimationId = 0;
  _activeAnimationKind = 0;
  _animationDelegate = nil;
  _springPausedForInactivity = NO;
  _pausedSpringHadMaskAnimation = NO;
  _pausedSpringHadShadowAnimation = NO;
  [_unequalCornerMask removeAnimationForKey:@"smoothClip.mask"];
  [_presentationContainer.layer removeAnimationForKey:@"smoothClip.appearance"];
  [_shadowLayer removeAnimationForKey:@"smoothClip.shadow"];
  if (_hasMaskAnimation) {
    [self applyStaticCornerRepresentation:[self canonicalGeometryValue]];
  }
  [self writeShadow:_requestedShadow
            geometry:[self canonicalGeometryValue]];
  [self syncVisibilityForRect:_canonicalClip];
  smoothclip::viewAnimationDidStop(
      driverId, animationId, self, finished);
  [self evaluateFlightLanding];
}

- (void)updateProps:(const Props::Shared &)props
            oldProps:(const Props::Shared &)oldProps {
  const auto &newProps =
      *std::static_pointer_cast<const SmoothClipViewProps>(props);
  [super updateProps:props oldProps:oldProps];
  self.clipsToBounds = YES;
  _flightEnabled = newProps.flightEnabled;
  NSString *flightTag =
      [NSString stringWithUTF8String:newProps.flightTag.c_str()] ?: @"";
  if (![flightTag isEqualToString:_flightTag]) {
    _flightTag = [flightTag copy];
    // A landed record pairs with the tag it landed on.
    if (![_flightLandedTag isEqualToString:flightTag]) {
      [self smoothClipFlightForgetLanding];
    }
  }

  const BOOL bakedShadows = newProps.shadowRendering == 1;
  if (bakedShadows != _bakedShadows) {
    _bakedShadows = bakedShadows;
    // Re-render the current shadow in the new mode. A run in flight keeps its
    // renderer to the end; its completion writes the model again.
    if (_activeAnimationId == 0 && _hasShadowModel) {
      [self writeShadow:_requestedShadow
               geometry:[self canonicalGeometryValue]];
    }
  }

  const uint64_t nextDriverId =
      isfinite(newProps.driverId) && newProps.driverId > 0
      ? static_cast<uint64_t>(newProps.driverId)
      : 0;
  smoothclip::Presentation initial{};
  if (!SmoothClipBuildPresentation(
          newProps.initialClipX,
          newProps.initialClipY,
          newProps.initialClipWidth,
          newProps.initialClipHeight,
          newProps.initialClipTopLeftRadius,
          newProps.initialClipTopRightRadius,
          newProps.initialClipBottomRightRadius,
          newProps.initialClipBottomLeftRadius,
          newProps.initialClipCurve,
          newProps.initialContentTranslateX,
          newProps.initialContentTranslateY,
          newProps.initialContentScale,
          newProps.initialClipBoxShadowEnabled,
          newProps.initialClipBoxShadowRed,
          newProps.initialClipBoxShadowGreen,
          newProps.initialClipBoxShadowBlue,
          newProps.initialClipBoxShadowAlpha,
          newProps.initialClipBoxShadowOffsetX,
          newProps.initialClipBoxShadowOffsetY,
          newProps.initialClipBoxShadowBlurRadius,
          newProps.initialClipBoxShadowSpreadDistance,
          newProps.initialRotation,
          newProps.initialOpacity,
          newProps.initialBackdropTranslateX,
          newProps.initialBackdropTranslateY,
          &initial)) {
    // The initial presentation is atomic. Never apply a valid subset when one
    // field rejects.
    return;
  }

  if (nextDriverId != _driverId) {
    if (_driverId != 0) {
      smoothclip::unregisterView(_driverId, self);
    }
    _driverId = nextDriverId;
    _commandIsAuthoritative = NO;
    if (_driverId != 0) {
      smoothclip::registerView(_driverId, self, initial);
    }
  } else if (_driverId == 0 && !_commandIsAuthoritative) {
    [self smoothClipApplyPresentation:initial];
  }
}

- (void)layoutContentContainer {
  [self writeAppearanceRotation:_canonicalRotation opacity:_canonicalOpacity rect:_canonicalClip];
  _contentContainer.layer.bounds = CGRectMake(
      0, 0, MAX(0, self.bounds.size.width), MAX(0, self.bounds.size.height));
  _contentContainer.layer.position = CGPointMake(
      MAX(0, self.bounds.size.width) / 2,
      MAX(0, self.bounds.size.height) / 2);
}

- (void)updateLayoutMetrics:(const LayoutMetrics &)layoutMetrics
             oldLayoutMetrics:(const LayoutMetrics &)oldLayoutMetrics {
  [super updateLayoutMetrics:layoutMetrics oldLayoutMetrics:oldLayoutMetrics];
  _hasLayout = YES;
  [self layoutContentContainer];
  if (_driverId != 0) {
    smoothclip::viewDisplayabilityChanged(_driverId, self);
  }
  if (_activeAnimationId == 0 &&
      (_driverId == 0 || !smoothclip::hasActiveAnimation(_driverId))) {
    [self applyRequestedClip];
  }
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
  if (![super pointInside:point withEvent:event]) return NO;
  SmoothClipCornerRadii radii = _canonicalRadii;
  const CGRect clip = _activeAnimationId != 0
      ? [self presentationRectWithRadii:&radii]
      : _canonicalClip;
  if ([self visibleOpacity] <= 0) return NO;
  const double rotation = [self visibleRotation];
  const CGPoint center = CGPointMake(CGRectGetMidX(clip), CGRectGetMidY(clip));
  const double dx = point.x - center.x, dy = point.y - center.y;
  point = CGPointMake(center.x + cos(rotation) * dx + sin(rotation) * dy,
                      center.y - sin(rotation) * dx + cos(rotation) * dy);
  if (CGRectIsEmpty(clip) || !CGRectContainsPoint(clip, point)) return NO;
  CGPathRef path = nil;
  if (_clipContainer.layer.mask == _unequalCornerMask) {
    CAShapeLayer *mask = _activeAnimationId != 0
        ? (CAShapeLayer *)_unequalCornerMask.presentationLayer
        : _unequalCornerMask;
    if (mask == nil) mask = _unequalCornerMask;
    path = mask.path;
    return path != nil && CGPathContainsPoint(path, NULL, point, NO);
  }
  path = SmoothClipCreateRoundedRectPath(clip, radii, _canonicalCurve);
  const BOOL contains = CGPathContainsPoint(path, NULL, point, NO);
  CGPathRelease(path);
  return contains;
}

#pragma mark - Native commands

- (void)handleCommand:(const NSString *)commandName args:(const NSArray *)args {
  RCTSmoothClipViewHandleCommand(self, commandName, args);
}

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
                           opacity:(double)opacity {
  smoothclip::Presentation presentation{};
  if (!SmoothClipBuildPresentation(
          x,
          y,
          width,
          height,
          topLeftRadius,
          topRightRadius,
          bottomRightRadius,
          bottomLeftRadius,
          curveCode,
          contentTranslateX,
          contentTranslateY,
          contentScale,
          shadowEnabled,
          shadowRed,
          shadowGreen,
          shadowBlue,
          shadowAlpha,
          shadowOffsetX,
          shadowOffsetY,
          shadowBlurRadius,
          shadowSpreadDistance,
          rotation,
          opacity,
          // The command protocol carries no backdrop channel; a command-driven
          // host keeps its backdrops where they are.
          0,
          0,
          &presentation)) {
    return;
  }
  _commandIsAuthoritative = YES;
  [self smoothClipApplyPresentation:presentation];
}

- (void)prepareForRecycle {
  if (_driverId != 0) {
    smoothclip::unregisterView(_driverId, self);
    _driverId = 0;
  }
  [self stopLayerAnimationWithoutCallback];
  smoothclip::clearVelocitySamples(_velocitySamples);
  [super prepareForRecycle];
  _requestedClip = CGRectZero;
  _canonicalClip = CGRectZero;
  _requestedRadius = 0;
  _canonicalRadius = 0;
  _requestedRadii = {0, 0, 0, 0};
  _canonicalRadii = {0, 0, 0, 0};
  _requestedCurve = SmoothClipCornerCurveCircular;
  _canonicalCurve = SmoothClipCornerCurveCircular;
  _requestedHasExplicitRadii = NO;
  _canonicalHasExplicitRadii = NO;
  _requestedContentTranslation = CGPointZero;
  _canonicalContentTranslation = CGPointZero;
  _requestedContentScale = 1;
  _canonicalContentScale = 1;
  _requestedShadow = {};
  _canonicalShadow = {};
  _requestedRotation = _canonicalRotation = 0;
  _requestedOpacity = _canonicalOpacity = 1;
  _presentationContainer.layer.affineTransform = CGAffineTransformIdentity;
  _presentationContainer.layer.opacity = 1;
  _hasLayout = NO;
  _commandIsAuthoritative = NO;

  CALayer *layer = _clipContainer.layer;
  layer.bounds = CGRectZero;
  layer.position = CGPointZero;
  layer.cornerRadius = 0;
  layer.cornerCurve = kCACornerCurveCircular;
  layer.mask = nil;
  _unequalCornerMask.path = nil;
  _contentContainer.layer.affineTransform = CGAffineTransformIdentity;
  _hasShadowModel = NO;
  _shadowLayer.shadowPath = nil;
  _shadowLayer.shadowOpacity = 0;
  _shadowLayer.shadowRadius = 0;
  _shadowLayer.shadowOffset = CGSizeZero;
  [self setClipContainerHidden:YES];
}

@end

@implementation SmoothClipAnimationDelegate

- (void)animationDidStop:(CAAnimation *)animation finished:(BOOL)finished {
  if (self.invalidated) return;
  [self.view smoothClipAnimationDidStopWithDriverId:self.driverId
                                        animationId:self.animationId
                                           finished:finished];
}

@end
