#import "SmoothClipView.h"

#import "SmoothClipGeometry.h"
#import "SmoothClipViewRegistry.h"

#include "SmoothClipAnimationCurve.h"
#include "SmoothClipVelocityTracker.h"

#import <QuartzCore/QuartzCore.h>
#import <React/RCTConversions.h>
#import <React/RCTFabricComponentsPlugins.h>
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

@end

@interface SmoothClipView () <RCTSmoothClipViewViewProtocol>
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
      geometry, contentTranslateX, contentTranslateY, contentScale, shadow};
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
    SmoothNormalizedClipGeometry geometry,
    const smoothclip::Shadow &shadow) {
  return shadow.enabled && shadow.alpha > 0 && !CGRectIsEmpty(geometry.rect);
}

static bool SmoothBoxShadowColorEqual(
    const smoothclip::Shadow &first,
    const smoothclip::Shadow &second) {
  return first.red == second.red && first.green == second.green &&
      first.blue == second.blue && first.alpha == second.alpha;
}

static bool SmoothBoxShadowPathInputEqual(
    SmoothNormalizedClipGeometry firstGeometry,
    const smoothclip::Shadow &firstShadow,
    SmoothNormalizedClipGeometry secondGeometry,
    const smoothclip::Shadow &secondShadow) {
  return CGRectEqualToRect(firstGeometry.rect, secondGeometry.rect) &&
      SmoothClipCornerRadiiEqual(
          firstGeometry.radii, secondGeometry.radii) &&
      firstGeometry.curve == secondGeometry.curve &&
      firstShadow.spreadDistance == secondShadow.spreadDistance;
}

static bool SmoothClipAllObjectsEqual(NSArray *values) {
  if (values.count < 2) return true;
  id first = values.firstObject;
  for (NSUInteger index = 1; index < values.count; index++) {
    if (![first isEqual:values[index]]) return false;
  }
  return true;
}

static bool SmoothClipAllPathsEqual(NSArray *values) {
  if (values.count < 2) return true;
  CGPathRef first = (__bridge CGPathRef)values.firstObject;
  for (NSUInteger index = 1; index < values.count; index++) {
    if (!CGPathEqualToPath(first, (__bridge CGPathRef)values[index])) {
      return false;
    }
  }
  return true;
}

static bool SmoothClipAllColorsEqual(NSArray *values) {
  if (values.count < 2) return true;
  CGColorRef first = (__bridge CGColorRef)values.firstObject;
  for (NSUInteger index = 1; index < values.count; index++) {
    if (!CGColorEqualToColor(first, (__bridge CGColorRef)values[index])) {
      return false;
    }
  }
  return true;
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
    SmoothNormalizedClipGeometry geometry,
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

@implementation SmoothClipView {
  CALayer *_shadowLayer;
  SmoothClipContainerView *_clipContainer;
  SmoothClipContainerView *_contentContainer;
  CAShapeLayer *_unequalCornerMask;
  CGRect _requestedClip;
  CGRect _normalizedClip;
  CGFloat _requestedRadius;
  CGFloat _normalizedRadius;
  SmoothClipCornerRadii _requestedRadii;
  SmoothClipCornerRadii _normalizedRadii;
  SmoothClipCornerCurve _requestedCurve;
  SmoothClipCornerCurve _normalizedCurve;
  BOOL _requestedHasExplicitRadii;
  BOOL _normalizedHasExplicitRadii;
  CGPoint _requestedContentTranslation;
  CGPoint _normalizedContentTranslation;
  CGFloat _requestedContentScale;
  CGFloat _normalizedContentScale;
  smoothclip::Shadow _requestedShadow;
  smoothclip::Shadow _normalizedShadow;
  uint64_t _driverId;
  BOOL _hasLayout;
  BOOL _commandIsAuthoritative;
  // Mirrors _clipContainer.hidden/.accessibilityElementsHidden so the hot
  // path can skip UIKit getters; every write goes through setClipContainerHidden.
  BOOL _clipHidden;
  BOOL _ignoreAnimationCallback;

  int32_t _activeAnimationId;
  NSInteger _activeAnimationKind;
  // Set when a native animation install arrived before the first layout.
  // The install is deferred and re-run through the registry at first layout
  // so it joins from live presentation geometry with the true remaining time.
  BOOL _pendingAnimationInstall;
  CFTimeInterval _animationStartedAt;
  CFTimeInterval _animationDuration;
  // Bumped on every CA install. updateLayoutMetrics captures it on entry so a
  // registry-driven install that happens inside its own lifecycle notification
  // (a latch resume during that very layout pass) is detectable: the local
  // rebuild must then be skipped, because its captured remaining time predates
  // the suspension and would shorten — or zero out — the fresh install.
  uint32_t _animationInstallGeneration;
  smoothclip::TimingAnimation _timingAnimation;
  smoothclip::SpringAnimation _springAnimation;
  SmoothClipAnimationDelegate *_animationDelegate;

  // 'inherit' velocity samples (normalized geometry, per view); recording/
  // coalescing/projection live in the shared cpp/SmoothClipVelocityTracker.h
  // (behavior-paired with Android's per-driver history).
  smoothclip::VelocitySampleHistory _velocitySamples;
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
    [self addSubview:_clipContainer];

    _shadowLayer = nil;
    // Created lazily so the common clipping-only path owns no shadow layer.

    _unequalCornerMask = [CAShapeLayer layer];
    _unequalCornerMask.actions = @{
      @"path": [NSNull null],
      @"bounds": [NSNull null],
      @"position": [NSNull null],
    };
    _unequalCornerMask.fillColor = UIColor.blackColor.CGColor;
    _unequalCornerMask.needsDisplayOnBoundsChange = NO;

    _requestedClip = CGRectZero;
    _normalizedClip = CGRectZero;
    _requestedRadius = 0;
    _normalizedRadius = 0;
    _requestedRadii = {0, 0, 0, 0};
    _normalizedRadii = {0, 0, 0, 0};
    _requestedCurve = SmoothClipCornerCurveCircular;
    _normalizedCurve = SmoothClipCornerCurveCircular;
    _requestedHasExplicitRadii = NO;
    _normalizedHasExplicitRadii = NO;
    _requestedContentTranslation = CGPointZero;
    _normalizedContentTranslation = CGPointZero;
    _requestedContentScale = 1;
    _normalizedContentScale = 1;
    _requestedShadow = {};
    _normalizedShadow = {};
    _driverId = 0;
    _hasLayout = NO;
    _commandIsAuthoritative = NO;
    _ignoreAnimationCallback = NO;
    _activeAnimationId = 0;
    _activeAnimationKind = 0;
    _pendingAnimationInstall = NO;
    _animationInstallGeneration = 0;
    smoothclip::clearVelocitySamples(_velocitySamples);
    // App-state transitions are observed by the registry itself (see
    // installApplicationStateObservers): the active flag is process-global,
    // so its observer must outlive any individual view.
  }
  return self;
}

- (void)dealloc {
  if (_driverId != 0) {
    smoothclip::unregisterView(_driverId, self);
  }
}

- (void)didMoveToWindow {
  [super didMoveToWindow];
  if (_driverId != 0) {
    smoothclip::viewDisplayabilityChanged(_driverId, self);
  }
}

- (void)mountChildComponentView:(UIView<RCTComponentViewProtocol> *)childComponentView
                          index:(NSInteger)index {
  NSAssert(childComponentView.superview == nil,
           @"SmoothClipView attempted to mount an already-mounted child");
  [_contentContainer insertSubview:childComponentView atIndex:index];
}

- (void)unmountChildComponentView:(UIView<RCTComponentViewProtocol> *)childComponentView
                            index:(NSInteger)index {
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
  };
  [self.layer insertSublayer:_shadowLayer below:_clipContainer.layer];
  return _shadowLayer;
}

- (void)writeShadow:(const smoothclip::Shadow &)shadow
            geometry:(SmoothNormalizedClipGeometry)geometry {
  _normalizedShadow = shadow;
  if (!shadow.enabled || CGRectIsEmpty(geometry.rect) || shadow.alpha <= 0) {
    if (_shadowLayer != nil) _shadowLayer.shadowOpacity = 0;
    return;
  }
  CALayer *shadowLayer = [self ensureShadowLayer];
  shadowLayer.bounds = self.bounds;
  shadowLayer.position = CGPointMake(
      CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
  CGPathRef path = SmoothClipCreateShadowPath(geometry, shadow);
  shadowLayer.shadowPath = path;
  CGPathRelease(path);
  shadowLayer.shadowColor = [self colorForShadow:shadow];
  shadowLayer.shadowOpacity = 1;
  shadowLayer.shadowRadius = MAX(0, shadow.blurRadius) / 2.0;
  shadowLayer.shadowOffset = CGSizeMake(shadow.offsetX, shadow.offsetY);
}

- (BOOL)normalizedRequestedGeometry:(SmoothNormalizedClipGeometry *)geometry {
  if (!_hasLayout) return NO;
#if defined(SMOOTH_CLIP_ENABLE_SIGNPOSTS) && SMOOTH_CLIP_ENABLE_SIGNPOSTS
  const bool signpostsEnabled =
      os_signpost_enabled([SmoothClipView signpostLog]);
  os_signpost_id_t identifier = OS_SIGNPOST_ID_NULL;
  if (signpostsEnabled) {
    identifier = os_signpost_id_generate([SmoothClipView signpostLog]);
    os_signpost_interval_begin(
        [SmoothClipView signpostLog], identifier, "normalization");
  }
#endif
  const CGSize hostSize = self.bounds.size;
  const BOOL valid = SmoothClipNormalizeGeometry(
      CGRectGetMinX(_requestedClip),
      CGRectGetMinY(_requestedClip),
      CGRectGetWidth(_requestedClip),
      CGRectGetHeight(_requestedClip),
      _requestedRadii.topLeft,
      _requestedRadii.topRight,
      _requestedRadii.bottomRight,
      _requestedRadii.bottomLeft,
      _requestedCurve,
      CGSizeMake(MAX(0, hostSize.width), MAX(0, hostSize.height)),
      geometry);
#if defined(SMOOTH_CLIP_ENABLE_SIGNPOSTS) && SMOOTH_CLIP_ENABLE_SIGNPOSTS
  if (signpostsEnabled) {
    os_signpost_interval_end(
        [SmoothClipView signpostLog], identifier, "normalization");
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
}

- (void)configureUnequalCornerMaskForGeometry:
    (SmoothNormalizedClipGeometry)geometry {
  const CGSize hostSize = self.bounds.size;
  _unequalCornerMask.bounds = CGRectMake(
      0, 0, MAX(0, hostSize.width), MAX(0, hostSize.height));
  _unequalCornerMask.position = CGPointMake(
      MAX(0, hostSize.width) / 2, MAX(0, hostSize.height) / 2);
  CGPathRef path = SmoothClipCreateRoundedRectPath(
      geometry.rect, geometry.radii, geometry.curve);
  _unequalCornerMask.path = path;
  CGPathRelease(path);
}

- (void)applyStaticCornerRepresentation:
    (SmoothNormalizedClipGeometry)geometry {
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

- (SmoothNormalizedClipGeometry)normalizedGeometryValue {
  return {
      .rect = _normalizedClip,
      .radius = _normalizedRadius,
      .radii = _normalizedRadii,
      .curve = _normalizedCurve,
  };
}

- (void)writeLayerGeometry:(SmoothNormalizedClipGeometry)geometry
         hasExplicitRadii:(BOOL)hasExplicitRadii {
  const BOOL rectChanged =
      !CGRectEqualToRect(_normalizedClip, geometry.rect);
  const BOOL radiiChanged =
      !SmoothClipCornerRadiiEqual(_normalizedRadii, geometry.radii);
  const BOOL curveChanged = _normalizedCurve != geometry.curve;
  const BOOL representationChanged =
      _normalizedHasExplicitRadii != hasExplicitRadii;
  _normalizedClip = geometry.rect;
  _normalizedRadius = geometry.radius;
  _normalizedRadii = geometry.radii;
  _normalizedCurve = geometry.curve;
  _normalizedHasExplicitRadii = hasExplicitRadii;
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

- (void)writeContentTranslation:(CGPoint)translation
                           scale:(CGFloat)scale {
  if (CGPointEqualToPoint(_normalizedContentTranslation, translation) &&
      _normalizedContentScale == scale) {
    return;
  }
  _normalizedContentTranslation = translation;
  _normalizedContentScale = scale;
  _contentContainer.layer.affineTransform =
      SmoothClipContentTransform(scale, translation);
}

- (void)applyRequestedClip {
  SmoothNormalizedClipGeometry geometry;
  if (![self normalizedRequestedGeometry:&geometry]) return;

  const BOOL visibilityChanged = _clipHidden != CGRectIsEmpty(geometry.rect);
  if (CGRectEqualToRect(_normalizedClip, geometry.rect) &&
      SmoothClipCornerRadiiEqual(_normalizedRadii, geometry.radii) &&
      _normalizedCurve == geometry.curve &&
      _normalizedHasExplicitRadii == _requestedHasExplicitRadii &&
      CGPointEqualToPoint(
          _normalizedContentTranslation, _requestedContentTranslation) &&
      _normalizedContentScale == _requestedContentScale &&
      SmoothBoxShadowEqual(_normalizedShadow, _requestedShadow) &&
      !visibilityChanged) {
    return;
  }
  [self writeLayerGeometry:geometry
         hasExplicitRadii:_requestedHasExplicitRadii];
  [self writeContentTranslation:_requestedContentTranslation
                           scale:_requestedContentScale];
  [self writeShadow:_requestedShadow geometry:geometry];
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
                contentTranslation:(CGPoint)targetContentTranslation {
  return smoothclip::inheritedVelocity(
      _velocitySamples,
      SmoothClipVelocityChannels(
          target,
          targetRadii,
          targetContentTranslation,
          _requestedContentScale),
      CACurrentMediaTime());
}

- (void)smoothClipApplyPresentation:(smoothclip::Presentation)presentation {
  [self smoothClipApplyPresentation:presentation recordVelocitySample:YES];
}

- (void)smoothClipApplyPresentation:(smoothclip::Presentation)presentation
               recordVelocitySample:(BOOL)recordVelocitySample {
  [self stopLayerAnimationWithoutCallback];
  [self storeRequestedPresentation:presentation];
  [self applyRequestedClip];
  // Skipped for writes that are not interactive motion (a latched
  // cancel-to-target): they must not enter the 'inherit' history.
  if (recordVelocitySample && _hasLayout) {
    [self recordInteractiveRect:_normalizedClip
                          radii:_normalizedRadii
             contentTranslation:_normalizedContentTranslation
                   contentScale:_normalizedContentScale];
  }
}

- (smoothclip::Presentation)smoothClipCurrentPresentation {
  SmoothClipCornerRadii visibleRadii = _normalizedRadii;
  const CGRect visibleRect = _activeAnimationId != 0
      ? [self presentationRectWithRadii:&visibleRadii]
      : _normalizedClip;
  CALayer *contentLayer = _activeAnimationId != 0
      ? (CALayer *)_contentContainer.layer.presentationLayer
      : _contentContainer.layer;
  if (contentLayer == nil) contentLayer = _contentContainer.layer;
  const CGAffineTransform transform = contentLayer.affineTransform;
  const BOOL uniform = SmoothClipCornerRadiiAreUniform(visibleRadii);
  smoothclip::Geometry geometry{
      CGRectGetMinX(visibleRect),
      CGRectGetMinY(visibleRect),
      CGRectGetWidth(visibleRect),
      CGRectGetHeight(visibleRect),
      uniform ? visibleRadii.topLeft : 0};
  if (_normalizedHasExplicitRadii || !uniform) {
    geometry.topLeftRadius = visibleRadii.topLeft;
    geometry.topRightRadius = visibleRadii.topRight;
    geometry.bottomRightRadius = visibleRadii.bottomRight;
    geometry.bottomLeftRadius = visibleRadii.bottomLeft;
  }
  geometry.curve = _normalizedCurve == SmoothClipCornerCurveContinuous
      ? smoothclip::ClipCurve::Continuous
      : smoothclip::ClipCurve::Circular;
  const CGFloat contentScale = hypot(transform.a, transform.b);
  smoothclip::Shadow shadow = _normalizedShadow;
  CALayer *shadowLayer = _activeAnimationId != 0 && _shadowLayer != nil
      ? (CALayer *)_shadowLayer.presentationLayer
      : _shadowLayer;
  if (shadowLayer == nil) return {
      geometry, transform.tx, transform.ty, contentScale, shadow};
  shadow.enabled = _normalizedShadow.enabled || shadowLayer.shadowOpacity > 0;
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
  return {geometry, transform.tx, transform.ty, contentScale, shadow};
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
  // latch starts must wait until a frame can actually be produced.
  return [self smoothClipIsJoinable] && self.window != nil &&
      smoothclip::applicationIsActive();
}

- (BOOL)smoothClipHasPendingInstall {
  return _pendingAnimationInstall;
}

- (void)smoothClipClearVelocitySamples {
  smoothclip::clearVelocitySamples(_velocitySamples);
}

- (double)smoothClipSpringContinuationVelocity {
  if (_activeAnimationId == 0 || _activeAnimationKind != 2 ||
      _pendingAnimationInstall) {
    return 0;
  }
  const double elapsed = MAX(0, CACurrentMediaTime() - _animationStartedAt);
  return smoothclip::springContinuationVelocity(_springAnimation, elapsed);
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
          mask.path, rect, _normalizedRadii);
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
  _pendingAnimationInstall = NO;
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
  [_shadowLayer removeAnimationForKey:@"smoothClip.shadow"];
  [self applyStaticCornerRepresentation:[self normalizedGeometryValue]];
  _ignoreAnimationCallback = NO;
  _activeAnimationId = 0;
  _activeAnimationKind = 0;
  _animationDelegate = nil;
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
  // Every key path in the group shares mass/stiffness/damping and the same
  // normalized initialVelocity, so one settling solve covers all of them.
  CASpringAnimation *probe =
      [CASpringAnimation animationWithKeyPath:@"bounds.origin.x"];
  probe.mass = _springAnimation.mass;
  probe.stiffness = _springAnimation.stiffness;
  probe.damping = _springAnimation.damping;
  probe.initialVelocity = velocity;
  return probe.settlingDuration;
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
            (SmoothNormalizedClipGeometry)fromGeometry
                   fromContentTranslation:(CGPoint)fromContentTranslation
                         fromContentScale:(CGFloat)fromContentScale
                              fromShadow:(smoothclip::Shadow)fromShadow
                               toGeometry:
            (SmoothNormalizedClipGeometry)toGeometry
                     hasExplicitToRadii:(BOOL)hasExplicitToRadii
                     toContentTranslation:(CGPoint)toContentTranslation
                           toContentScale:(CGFloat)toContentScale
                                toShadow:(smoothclip::Shadow)toShadow
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
  const BOOL usesMask =
      !SmoothClipCornerRadiiAreUniform(fromGeometry.radii) ||
      !SmoothClipCornerRadiiAreUniform(toGeometry.radii) ||
      fromGeometry.curve != toGeometry.curve;
  [self writeLayerGeometry:toGeometry
         hasExplicitRadii:hasExplicitToRadii];
  [self writeContentTranslation:toContentTranslation scale:toContentScale];
  [self writeShadow:toShadow geometry:toGeometry];
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
  const BOOL animatesShadowOpacity =
      fromShadowVisible != toShadowVisible;
  const BOOL animatesShadowRadius = hasVisibleShadow &&
      fromShadow.blurRadius != toShadow.blurRadius;
  const BOOL animatesShadowOffset = hasVisibleShadow &&
      (fromShadow.offsetX != toShadow.offsetX ||
       fromShadow.offsetY != toShadow.offsetY);
  const BOOL animatesShadow = animatesShadowPath || animatesShadowColor ||
      animatesShadowOpacity || animatesShadowRadius || animatesShadowOffset;
  if (animatesShadow) [self ensureShadowLayer];
  CGPathRef fromShadowPath = animatesShadowPath
      ? SmoothClipCreateShadowPath(fromGeometry, fromShadow)
      : nil;
  CGPathRef toShadowPath = animatesShadowPath
      ? SmoothClipCreateShadowPath(toGeometry, toShadow)
      : nil;
  const float fromShadowOpacity = fromShadowVisible ? 1 : 0;
  const float toShadowOpacity = toShadowVisible ? 1 : 0;

  CAAnimationGroup *group = [CAAnimationGroup animation];
  CAAnimationGroup *contentGroup = [CAAnimationGroup animation];
  CAAnimationGroup *shadowGroup = animatesShadow
      ? [CAAnimationGroup animation]
      : nil;
  CAAnimation *maskAnimation = nil;
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
      maskAnimation = [self basicAnimationForKeyPath:@"path"
                                           fromValue:(__bridge id)fromMaskPath
                                             toValue:(__bridge id)toMaskPath
                                      timingFunction:timing];
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
    if (animatesShadow) {
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
      if (animatesShadowOpacity) [shadowAnimations addObject:
          [self basicAnimationForKeyPath:@"shadowOpacity"
                           fromValue:@(fromShadowOpacity)
                             toValue:@(toShadowOpacity)
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
      maskAnimation = [self springAnimationForKeyPath:@"path"
                                            fromValue:(__bridge id)fromMaskPath
                                              toValue:(__bridge id)toMaskPath
                                             velocity:velocity
                                             duration:springDuration];
    } else {
      [geometryAnimations addObject:
          [self springAnimationForKeyPath:@"cornerRadius"
                                fromValue:@(fromGeometry.radii.topLeft)
                                  toValue:@(toGeometry.radii.topLeft)
                                 velocity:velocity
                                 duration:springDuration]];
    }
    group.animations = geometryAnimations;
    // A rebuilt spring (layout change, foreground resume) must run its own
    // settling time; clamping to the interrupted run's remaining wall-clock
    // time would truncate the oscillation and snap to the target.
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
    if (animatesShadow) {
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
      if (animatesShadowOpacity) [shadowAnimations addObject:
          [self springAnimationForKeyPath:@"shadowOpacity"
                            fromValue:@(fromShadowOpacity)
                              toValue:@(toShadowOpacity)
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

  if (sharedBeginTime > 0) {
    // Each layer receives the same absolute media timestamp translated into
    // its local clock. Group participants therefore advance from one epoch
    // even though their animations are installed sequentially.
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

  _animationDuration = group.duration;
  _animationStartedAt = sharedBeginTime > 0
      ? sharedBeginTime
      : CACurrentMediaTime();
  _animationDelegate = [SmoothClipAnimationDelegate new];
  _animationDelegate.view = self;
  _animationDelegate.driverId = _driverId;
  _animationDelegate.animationId = _activeAnimationId;
  group.delegate = _animationDelegate;
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
  _animationInstallGeneration += 1;
}

- (BOOL)startAnimationToRequestedGeometryWithDuration:(CFTimeInterval)duration
                                       sharedBeginTime:
                                           (CFTimeInterval)sharedBeginTime {
  if (![self smoothClipCanDisplay]) {
    _pendingAnimationInstall = YES;
    return NO;
  }
  SmoothNormalizedClipGeometry target;
  if (![self normalizedRequestedGeometry:&target]) return NO;
  const smoothclip::Presentation current = [self smoothClipCurrentPresentation];
  const SmoothClipCornerRadii currentRadii =
      SmoothClipPresentationRadii(current.clip);
  const SmoothNormalizedClipGeometry fromGeometry = {
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
                          toGeometry:target
                hasExplicitToRadii:_requestedHasExplicitRadii
                toContentTranslation:_requestedContentTranslation
                      toContentScale:_requestedContentScale
                           toShadow:_requestedShadow
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
    SmoothNormalizedClipGeometry target;
    if ([self normalizedRequestedGeometry:&target]) {
      _springAnimation.initialVelocity =
          [self inheritedVelocityToRect:target.rect
                                   radii:target.radii
                      contentTranslation:_requestedContentTranslation];
    } else {
      _springAnimation.initialVelocity = 0;
    }
  }
  _activeAnimationKind = 2;
  _activeAnimationId = animationId;
  return [self startAnimationToRequestedGeometryWithDuration:0
                                              sharedBeginTime:sharedBeginTime];
}

- (CAKeyframeAnimation *)keyframeAnimationForKeyPath:(NSString *)keyPath
                                               values:(NSArray *)values
                                             keyTimes:(NSArray<NSNumber *> *)keyTimes {
  CAKeyframeAnimation *animation =
      [CAKeyframeAnimation animationWithKeyPath:keyPath];
  animation.values = values;
  animation.keyTimes = keyTimes;
  animation.calculationMode = kCAAnimationLinear;
  return animation;
}

- (BOOL)smoothClipAnimateKeyframes:(smoothclip::Presentation)presentation
                          keyframes:(const std::vector<smoothclip::Keyframe> &)keyframes
                          durationMs:(double)durationMs
                         animationId:(int32_t)animationId {
  return [self smoothClipAnimateKeyframes:presentation
                                keyframes:keyframes
                               durationMs:durationMs
                              animationId:animationId
                          sharedBeginTime:0];
}

- (BOOL)smoothClipAnimateKeyframes:(smoothclip::Presentation)presentation
                          keyframes:(const std::vector<smoothclip::Keyframe> &)keyframes
                          durationMs:(double)durationMs
                         animationId:(int32_t)animationId
                     sharedBeginTime:(CFTimeInterval)sharedBeginTime {
  if (keyframes.size() < 2) return NO;
  [self storeRequestedPresentation:presentation];
  _activeAnimationKind = 3;
  _activeAnimationId = animationId;
  if (![self smoothClipCanDisplay]) {
    _pendingAnimationInstall = YES;
    return NO;
  }
  [self stopLayerAnimationWithoutCallback];
  _activeAnimationKind = 3;
  _activeAnimationId = animationId;

  const NSUInteger frameCount = keyframes.size();
  const BOOL hasVisibleShadowFrame = std::any_of(
      keyframes.begin(), keyframes.end(),
      [](const smoothclip::Keyframe &frame) {
        return frame.presentation.shadow.enabled &&
            frame.presentation.shadow.alpha > 0;
      });
  const CGSize hostSize = self.bounds.size;
  NSMutableArray<NSNumber *> *times =
      [NSMutableArray arrayWithCapacity:frameCount];
  NSMutableArray *boundsValues = [NSMutableArray arrayWithCapacity:frameCount];
  NSMutableArray *positionValues =
      [NSMutableArray arrayWithCapacity:frameCount];
  NSMutableArray *radiusValues = [NSMutableArray arrayWithCapacity:frameCount];
  NSMutableArray *maskPathValues =
      [NSMutableArray arrayWithCapacity:frameCount];
  NSMutableArray *translateXValues =
      [NSMutableArray arrayWithCapacity:frameCount];
  NSMutableArray *translateYValues =
      [NSMutableArray arrayWithCapacity:frameCount];
  NSMutableArray *scaleValues =
      [NSMutableArray arrayWithCapacity:frameCount];
  NSMutableArray *shadowPathValues = hasVisibleShadowFrame
      ? [NSMutableArray arrayWithCapacity:frameCount] : nil;
  NSMutableArray *shadowColorValues = hasVisibleShadowFrame
      ? [NSMutableArray arrayWithCapacity:frameCount] : nil;
  NSMutableArray *shadowOpacityValues = hasVisibleShadowFrame
      ? [NSMutableArray arrayWithCapacity:frameCount] : nil;
  NSMutableArray *shadowRadiusValues = hasVisibleShadowFrame
      ? [NSMutableArray arrayWithCapacity:frameCount] : nil;
  NSMutableArray *shadowOffsetValues = hasVisibleShadowFrame
      ? [NSMutableArray arrayWithCapacity:frameCount] : nil;
  BOOL usesMask = NO;
  BOOL animatesScale = NO;
  SmoothClipCornerCurve firstCurve = SmoothClipCornerCurveCircular;
  BOOL hasFirstCurve = NO;
  std::vector<SmoothNormalizedClipGeometry> normalizedFrames;
  normalizedFrames.reserve(frameCount);
  for (const smoothclip::Keyframe &frame : keyframes) {
    const SmoothClipCornerRadii frameRadii =
        SmoothClipPresentationRadii(frame.presentation.clip);
    const SmoothClipCornerCurve frameCurve =
        SmoothClipPresentationCurve(frame.presentation.clip);
    SmoothNormalizedClipGeometry normalized;
    if (!SmoothClipNormalizeGeometry(
            frame.presentation.clip.x,
            frame.presentation.clip.y,
            frame.presentation.clip.width,
            frame.presentation.clip.height,
            frameRadii.topLeft,
            frameRadii.topRight,
            frameRadii.bottomRight,
            frameRadii.bottomLeft,
            frameCurve,
            hostSize,
            &normalized)) return NO;
    normalizedFrames.push_back(normalized);
    if (!SmoothClipCornerRadiiAreUniform(normalized.radii)) usesMask = YES;
    if (!hasFirstCurve) {
      firstCurve = normalized.curve;
      hasFirstCurve = YES;
    } else if (normalized.curve != firstCurve) {
      usesMask = YES;
    }
    if (frame.presentation.contentScale != 1) animatesScale = YES;
    [times addObject:@(frame.offset)];
    [boundsValues addObject:[NSValue valueWithCGRect:normalized.rect]];
    [positionValues addObject:[NSValue valueWithCGPoint:CGPointMake(
        CGRectGetMidX(normalized.rect), CGRectGetMidY(normalized.rect))]];
    [radiusValues addObject:@(normalized.radius)];
    [translateXValues addObject:@(frame.presentation.contentTranslateX)];
    [translateYValues addObject:@(frame.presentation.contentTranslateY)];
    [scaleValues addObject:@(frame.presentation.contentScale)];
    if (hasVisibleShadowFrame) {
      CGPathRef shadowPath = SmoothClipCreateShadowPath(
          normalized, frame.presentation.shadow);
      [shadowPathValues addObject:(__bridge id)shadowPath];
      CGPathRelease(shadowPath);
      [shadowColorValues addObject:
          (__bridge id)[self colorForShadow:frame.presentation.shadow]];
      [shadowOpacityValues addObject:@(
          frame.presentation.shadow.enabled &&
                  !CGRectIsEmpty(normalized.rect) &&
                  frame.presentation.shadow.alpha > 0
              ? 1
              : 0)];
      [shadowRadiusValues addObject:@(
          MAX(0, frame.presentation.shadow.blurRadius) / 2.0)];
      [shadowOffsetValues addObject:[NSValue valueWithCGSize:CGSizeMake(
          frame.presentation.shadow.offsetX,
          frame.presentation.shadow.offsetY)]];
    }
  }

  if (usesMask) {
    for (const SmoothNormalizedClipGeometry &normalized : normalizedFrames) {
      CGPathRef path = SmoothClipCreateRoundedRectPath(
          normalized.rect, normalized.radii, normalized.curve);
      [maskPathValues addObject:(__bridge id)path];
      CGPathRelease(path);
    }
  }

  const BOOL animatesShadowPath = hasVisibleShadowFrame &&
      !SmoothClipAllPathsEqual(shadowPathValues);
  const BOOL animatesShadowColor = hasVisibleShadowFrame &&
      !SmoothClipAllColorsEqual(shadowColorValues);
  const BOOL animatesShadowOpacity = hasVisibleShadowFrame &&
      !SmoothClipAllObjectsEqual(shadowOpacityValues);
  const BOOL animatesShadowRadius = hasVisibleShadowFrame &&
      !SmoothClipAllObjectsEqual(shadowRadiusValues);
  const BOOL animatesShadowOffset = hasVisibleShadowFrame &&
      !SmoothClipAllObjectsEqual(shadowOffsetValues);
  const BOOL animatesShadow = animatesShadowPath || animatesShadowColor ||
      animatesShadowOpacity || animatesShadowRadius || animatesShadowOffset;
  if (animatesShadow) [self ensureShadowLayer];

  SmoothNormalizedClipGeometry target;
  if (![self normalizedRequestedGeometry:&target]) return NO;
  [self writeLayerGeometry:target
         hasExplicitRadii:_requestedHasExplicitRadii];
  [self writeContentTranslation:_requestedContentTranslation
                           scale:_requestedContentScale];
  [self writeShadow:_requestedShadow geometry:target];
  if (usesMask) {
    [self configureUnequalCornerMaskForGeometry:target];
    _clipContainer.layer.cornerRadius = 0;
    _clipContainer.layer.mask = _unequalCornerMask;
  }
  [self setClipContainerHidden:NO];

  CAAnimationGroup *group = [CAAnimationGroup animation];
  NSMutableArray<CAAnimation *> *geometryAnimations = [NSMutableArray arrayWithArray:@[
    [self keyframeAnimationForKeyPath:@"bounds"
                               values:boundsValues
                             keyTimes:times],
    [self keyframeAnimationForKeyPath:@"position"
                               values:positionValues
                             keyTimes:times],
  ]];
  if (!usesMask) {
    [geometryAnimations addObject:
        [self keyframeAnimationForKeyPath:@"cornerRadius"
                                   values:radiusValues
                                 keyTimes:times]];
  }
  group.animations = geometryAnimations;
  group.duration = MAX(0, durationMs) / 1000.0;
  CAAnimationGroup *contentGroup = [CAAnimationGroup animation];
  NSMutableArray<CAAnimation *> *contentAnimations = [NSMutableArray arrayWithArray:@[
    [self keyframeAnimationForKeyPath:@"transform.translation.x"
                               values:translateXValues
                             keyTimes:times],
    [self keyframeAnimationForKeyPath:@"transform.translation.y"
                               values:translateYValues
                             keyTimes:times],
  ]];
  if (animatesScale) {
    [contentAnimations addObject:
        [self keyframeAnimationForKeyPath:@"transform.scale"
                                   values:scaleValues
                                 keyTimes:times]];
  }
  contentGroup.animations = contentAnimations;
  contentGroup.duration = group.duration;
  CAAnimationGroup *shadowGroup = animatesShadow
      ? [CAAnimationGroup animation]
      : nil;
  if (animatesShadow) {
    NSMutableArray<CAAnimation *> *shadowAnimations = [NSMutableArray array];
    if (animatesShadowPath) [shadowAnimations addObject:
        [self keyframeAnimationForKeyPath:@"shadowPath"
                               values:shadowPathValues
                             keyTimes:times]];
    if (animatesShadowColor) [shadowAnimations addObject:
        [self keyframeAnimationForKeyPath:@"shadowColor"
                               values:shadowColorValues
                             keyTimes:times]];
    if (animatesShadowOpacity) [shadowAnimations addObject:
        [self keyframeAnimationForKeyPath:@"shadowOpacity"
                               values:shadowOpacityValues
                             keyTimes:times]];
    if (animatesShadowRadius) [shadowAnimations addObject:
        [self keyframeAnimationForKeyPath:@"shadowRadius"
                               values:shadowRadiusValues
                             keyTimes:times]];
    if (animatesShadowOffset) [shadowAnimations addObject:
        [self keyframeAnimationForKeyPath:@"shadowOffset"
                               values:shadowOffsetValues
                             keyTimes:times]];
    shadowGroup.animations = shadowAnimations;
    shadowGroup.duration = group.duration;
  }

  CAKeyframeAnimation *maskAnimation = usesMask
      ? [self keyframeAnimationForKeyPath:@"path"
                                  values:maskPathValues
                                keyTimes:times]
      : nil;
  maskAnimation.duration = group.duration;

  if (sharedBeginTime > 0) {
    group.beginTime = [_clipContainer.layer
        convertTime:sharedBeginTime
        fromLayer:nil];
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

  _animationDuration = group.duration;
  _animationStartedAt = sharedBeginTime > 0
      ? sharedBeginTime
      : CACurrentMediaTime();
  _animationDelegate = [SmoothClipAnimationDelegate new];
  _animationDelegate.view = self;
  _animationDelegate.driverId = _driverId;
  _animationDelegate.animationId = _activeAnimationId;
  group.delegate = _animationDelegate;
  [_clipContainer.layer addAnimation:group forKey:@"smoothClip.geometry"];
  [_contentContainer.layer addAnimation:contentGroup
                                 forKey:@"smoothClip.content"];
  if (animatesShadow) {
    [_shadowLayer addAnimation:shadowGroup forKey:@"smoothClip.shadow"];
  }
  if (maskAnimation != nil) {
    [_unequalCornerMask addAnimation:maskAnimation forKey:@"smoothClip.mask"];
  }
  _animationInstallGeneration += 1;
  return YES;
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

- (void)smoothClipAnimationDidStopWithDriverId:(uint64_t)driverId
                                    animationId:(int32_t)animationId
                                       finished:(BOOL)finished {
  if (_ignoreAnimationCallback || animationId != _activeAnimationId) return;
  _activeAnimationId = 0;
  _activeAnimationKind = 0;
  _animationDelegate = nil;
  [_unequalCornerMask removeAnimationForKey:@"smoothClip.mask"];
  [_shadowLayer removeAnimationForKey:@"smoothClip.shadow"];
  [self applyStaticCornerRepresentation:[self normalizedGeometryValue]];
  [self syncVisibilityForRect:_normalizedClip];
  smoothclip::viewAnimationDidStop(
      driverId, animationId, self, finished);
}

- (void)updateProps:(const Props::Shared &)props
            oldProps:(const Props::Shared &)oldProps {
  const auto &newProps =
      *std::static_pointer_cast<const SmoothClipViewProps>(props);
  [super updateProps:props oldProps:oldProps];

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
  _contentContainer.layer.bounds = CGRectMake(
      0, 0, MAX(0, self.bounds.size.width), MAX(0, self.bounds.size.height));
  _contentContainer.layer.position = CGPointMake(
      MAX(0, self.bounds.size.width) / 2,
      MAX(0, self.bounds.size.height) / 2);
}

- (void)updateLayoutMetrics:(const LayoutMetrics &)layoutMetrics
             oldLayoutMetrics:(const LayoutMetrics &)oldLayoutMetrics {
  const BOOL wasAnimating = _activeAnimationId != 0;
  const BOOL wasPending = _pendingAnimationInstall;
  const uint32_t installGenerationAtEntry = _animationInstallGeneration;
  const smoothclip::Presentation visible = wasAnimating && !wasPending
      ? [self smoothClipCurrentPresentation]
      : smoothclip::Presentation{{0, 0, 0, 0, 0}, 0, 0, 1};
  const CGRect visibleRect = CGRectMake(
      visible.clip.x,
      visible.clip.y,
      visible.clip.width,
      visible.clip.height);
  const SmoothClipCornerRadii visibleRadii =
      SmoothClipPresentationRadii(visible.clip);
  const SmoothClipCornerCurve visibleCurve =
      SmoothClipPresentationCurve(visible.clip);
  const CGPoint visibleContentTranslation = CGPointMake(
      visible.contentTranslateX,
      visible.contentTranslateY);
  const CGFloat visibleContentScale = visible.contentScale;
  CFTimeInterval remaining = wasAnimating
      ? MAX(0, _animationDuration -
                   (CACurrentMediaTime() - _animationStartedAt))
      : 0;
  const double springContinuationVelocity =
      wasAnimating && !wasPending && _activeAnimationKind == 2
      ? [self smoothClipSpringContinuationVelocity]
      : 0;

  [super updateLayoutMetrics:layoutMetrics oldLayoutMetrics:oldLayoutMetrics];
  _hasLayout = YES;
  [self layoutContentContainer];
  if (_driverId != 0) {
    // Both edges matter: zero size/detach/background suspend an installed
    // participant; the first positive visible layout resumes the held latch.
    smoothclip::viewDisplayabilityChanged(_driverId, self);
  }
  if (wasPending) {
    // The registry either kept the install deferred or installed the rebased
    // latch. Relayout must not independently restart a background-held id.
    if (_activeAnimationId == 0) [self applyRequestedClip];
    return;
  }
  if (wasAnimating) {
    // A negative transition may have frozen this host and re-latched the
    // registry above. Its non-recording freeze is already the correct model
    // state for the new lifecycle; do not resurrect a local timer.
    if (_activeAnimationId == 0 || ![self smoothClipCanDisplay]) return;
    // The lifecycle notification above may itself have installed this
    // animation from the registry's trimmed remainder (a latch resume inside
    // this very layout pass). That install rebased the clocks; the `remaining`
    // captured on entry predates the suspension and would rebuild a shorter —
    // possibly zero-duration — run on top of the fresh one. The id alone
    // cannot detect this (a resume keeps the animation id), so compare the
    // install generation.
    if (_animationInstallGeneration != installGenerationAtEntry) return;
    const int32_t animationId = _activeAnimationId;
    const NSInteger animationKind = _activeAnimationKind;
    [self stopLayerAnimationWithoutCallback];
    _activeAnimationId = animationId;
    _activeAnimationKind = animationKind;
    if (_activeAnimationKind == 1 && _animationDuration > 0) {
      const double progress = smoothclip::clamp01(
          1 - remaining / _animationDuration);
      _timingAnimation =
          smoothclip::timingRemainder(_timingAnimation, progress).animation;
      remaining = _timingAnimation.durationMs / 1000.0;
    } else if (_activeAnimationKind == 2) {
      _springAnimation.initialVelocity = springContinuationVelocity;
      _springAnimation.inheritVelocity = false;
    } else if (_activeAnimationKind == 3) {
      _activeAnimationKind = 1;
      _timingAnimation = {remaining * 1000.0, 0, 0, 1, 1, 2};
    }
    SmoothNormalizedClipGeometry current;
    SmoothClipNormalizeGeometry(
        CGRectGetMinX(visibleRect),
        CGRectGetMinY(visibleRect),
        CGRectGetWidth(visibleRect),
        CGRectGetHeight(visibleRect),
        visibleRadii.topLeft,
        visibleRadii.topRight,
        visibleRadii.bottomRight,
        visibleRadii.bottomLeft,
        visibleCurve,
        self.bounds.size,
        &current);
    SmoothNormalizedClipGeometry target;
    if ([self normalizedRequestedGeometry:&target]) {
      [self installAnimationFromGeometry:current
                  fromContentTranslation:visibleContentTranslation
                        fromContentScale:visibleContentScale
                             fromShadow:visible.shadow
                              toGeometry:target
                    hasExplicitToRadii:_requestedHasExplicitRadii
                    toContentTranslation:_requestedContentTranslation
                              toContentScale:_requestedContentScale
                                  toShadow:_requestedShadow
                                duration:remaining
                         sharedBeginTime:0];
    }
  } else {
    if (_driverId != 0 && smoothclip::hasActiveAnimation(_driverId)) {
      // Registry-level lifecycle pause owns the frozen model. A layout pass
      // while its latch is held must not apply the requested target or start a
      // per-view timer; foreground/reattach will normalize and resume it once.
      return;
    }
    [self applyRequestedClip];
  }
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
  if (![super pointInside:point withEvent:event]) return NO;
  SmoothClipCornerRadii radii = _normalizedRadii;
  const CGRect clip = _activeAnimationId != 0
      ? [self presentationRectWithRadii:&radii]
      : _normalizedClip;
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
  path = SmoothClipCreateRoundedRectPath(clip, radii, _normalizedCurve);
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
              shadowSpreadDistance:(double)shadowSpreadDistance {
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
  _pendingAnimationInstall = NO;
  smoothclip::clearVelocitySamples(_velocitySamples);
  [super prepareForRecycle];
  _requestedClip = CGRectZero;
  _normalizedClip = CGRectZero;
  _requestedRadius = 0;
  _normalizedRadius = 0;
  _requestedRadii = {0, 0, 0, 0};
  _normalizedRadii = {0, 0, 0, 0};
  _requestedCurve = SmoothClipCornerCurveCircular;
  _normalizedCurve = SmoothClipCornerCurveCircular;
  _requestedHasExplicitRadii = NO;
  _normalizedHasExplicitRadii = NO;
  _requestedContentTranslation = CGPointZero;
  _normalizedContentTranslation = CGPointZero;
  _requestedContentScale = 1;
  _normalizedContentScale = 1;
  _requestedShadow = {};
  _normalizedShadow = {};
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
