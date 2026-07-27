#import "SmoothClipView.h"

#import "SmoothClipGeometry.h"
#import "SmoothClipViewRegistry.h"

#import <QuartzCore/QuartzCore.h>
#import <React/RCTConversions.h>
#import <React/RCTFabricComponentsPlugins.h>
#if defined(SMOOTH_CLIP_ENABLE_SIGNPOSTS) && SMOOTH_CLIP_ENABLE_SIGNPOSTS
#import <os/signpost.h>
#endif
#import <react/renderer/components/SmoothClipViewSpec/ComponentDescriptors.h>
#import <react/renderer/components/SmoothClipViewSpec/Props.h>
#import <react/renderer/components/SmoothClipViewSpec/RCTComponentViewHelpers.h>

#include <cfloat>

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

@implementation SmoothClipView {
  SmoothClipContainerView *_clipContainer;
  SmoothClipContainerView *_contentContainer;
  CGRect _requestedClip;
  CGRect _normalizedClip;
  CGFloat _requestedRadius;
  CGFloat _normalizedRadius;
  CGPoint _requestedContentTranslation;
  CGPoint _normalizedContentTranslation;
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
  smoothclip::TimingAnimation _timingAnimation;
  smoothclip::SpringAnimation _springAnimation;
  SmoothClipAnimationDelegate *_animationDelegate;
  BOOL _animationPaused;
  CGRect _pausedRect;
  CGFloat _pausedRadius;
  CGPoint _pausedContentTranslation;
  CFTimeInterval _pausedRemaining;

  BOOL _hasPreviousInteractiveSample;
  BOOL _hasInteractiveSample;
  CGRect _previousInteractiveRect;
  CGRect _interactiveRect;
  CGFloat _previousInteractiveRadius;
  CGFloat _interactiveRadius;
  CGPoint _previousInteractiveContentTranslation;
  CGPoint _interactiveContentTranslation;
  CFTimeInterval _previousInteractiveTime;
  CFTimeInterval _interactiveTime;
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

    _requestedClip = CGRectZero;
    _normalizedClip = CGRectZero;
    _requestedRadius = 0;
    _normalizedRadius = 0;
    _requestedContentTranslation = CGPointZero;
    _normalizedContentTranslation = CGPointZero;
    _driverId = 0;
    _hasLayout = NO;
    _commandIsAuthoritative = NO;
    _ignoreAnimationCallback = NO;
    _activeAnimationId = 0;
    _activeAnimationKind = 0;
    _pendingAnimationInstall = NO;
    _animationPaused = NO;
    _hasPreviousInteractiveSample = NO;
    _hasInteractiveSample = NO;
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(applicationWillResignActive)
               name:UIApplicationWillResignActiveNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(applicationDidBecomeActive)
               name:UIApplicationDidBecomeActiveNotification
             object:nil];
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  if (_driverId != 0) {
    smoothclip::unregisterView(_driverId, self);
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
  _requestedRadius = MAX(0, geometry.radius);
  _requestedContentTranslation = CGPointMake(
      presentation.contentTranslateX,
      presentation.contentTranslateY);
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
      _requestedRadius,
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

- (void)writeLayerRect:(CGRect)rect radius:(CGFloat)radius {
  const BOOL rectChanged = !CGRectEqualToRect(_normalizedClip, rect);
  const BOOL radiusChanged = _normalizedRadius != radius;
  _normalizedClip = rect;
  _normalizedRadius = radius;
  if (!rectChanged && !radiusChanged) return;

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
    layer.bounds = rect;
    layer.position = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
  }
  if (radiusChanged) {
    layer.cornerRadius = radius;
  }
#if defined(SMOOTH_CLIP_ENABLE_SIGNPOSTS) && SMOOTH_CLIP_ENABLE_SIGNPOSTS
  if (signpostsEnabled) {
    os_signpost_interval_end(
        [SmoothClipView signpostLog], identifier, "layer-application");
  }
#endif
}

- (void)writeContentTranslation:(CGPoint)translation {
  if (CGPointEqualToPoint(_normalizedContentTranslation, translation)) return;
  _normalizedContentTranslation = translation;
  _contentContainer.layer.affineTransform =
      CGAffineTransformMakeTranslation(translation.x, translation.y);
}

- (void)applyRequestedClip {
  SmoothNormalizedClipGeometry geometry;
  if (![self normalizedRequestedGeometry:&geometry]) return;

  const BOOL visibilityChanged = _clipHidden != CGRectIsEmpty(geometry.rect);
  if (CGRectEqualToRect(_normalizedClip, geometry.rect) &&
      _normalizedRadius == geometry.radius &&
      CGPointEqualToPoint(
          _normalizedContentTranslation, _requestedContentTranslation) &&
      !visibilityChanged) {
    return;
  }
  [self writeLayerRect:geometry.rect radius:geometry.radius];
  [self writeContentTranslation:_requestedContentTranslation];
  [self syncVisibilityForRect:geometry.rect];
}

- (void)recordInteractiveRect:(CGRect)rect
                       radius:(CGFloat)radius
           contentTranslation:(CGPoint)contentTranslation {
  if (_hasInteractiveSample &&
      CGRectEqualToRect(_interactiveRect, rect) &&
      _interactiveRadius == radius &&
      CGPointEqualToPoint(
          _interactiveContentTranslation, contentTranslation)) {
    return;
  }
  if (_hasInteractiveSample) {
    _hasPreviousInteractiveSample = YES;
    _previousInteractiveRect = _interactiveRect;
    _previousInteractiveRadius = _interactiveRadius;
    _previousInteractiveContentTranslation =
        _interactiveContentTranslation;
    _previousInteractiveTime = _interactiveTime;
  }
  _hasInteractiveSample = YES;
  _interactiveRect = rect;
  _interactiveRadius = radius;
  _interactiveContentTranslation = contentTranslation;
  _interactiveTime = CACurrentMediaTime();
}

- (CGFloat)inheritedVelocityToRect:(CGRect)target
                            radius:(CGFloat)targetRadius
                contentTranslation:(CGPoint)targetContentTranslation {
  if (!_hasPreviousInteractiveSample || !_hasInteractiveSample) return 0;
  const CFTimeInterval elapsed =
      _interactiveTime - _previousInteractiveTime;
  if (elapsed <= 0 || CACurrentMediaTime() - _interactiveTime > 0.1) return 0;

  const CGFloat current[] = {
      CGRectGetMinX(_interactiveRect),
      CGRectGetMinY(_interactiveRect),
      CGRectGetWidth(_interactiveRect),
      CGRectGetHeight(_interactiveRect),
      _interactiveRadius,
      _interactiveContentTranslation.x,
      _interactiveContentTranslation.y};
  const CGFloat previous[] = {
      CGRectGetMinX(_previousInteractiveRect),
      CGRectGetMinY(_previousInteractiveRect),
      CGRectGetWidth(_previousInteractiveRect),
      CGRectGetHeight(_previousInteractiveRect),
      _previousInteractiveRadius,
      _previousInteractiveContentTranslation.x,
      _previousInteractiveContentTranslation.y};
  const CGFloat destination[] = {
      CGRectGetMinX(target),
      CGRectGetMinY(target),
      CGRectGetWidth(target),
      CGRectGetHeight(target),
      targetRadius,
      targetContentTranslation.x,
      targetContentTranslation.y};
  double numerator = 0;
  double denominator = 0;
  for (NSUInteger index = 0; index < 7; index += 1) {
    const double velocity = (current[index] - previous[index]) / elapsed;
    const double displacement = destination[index] - current[index];
    numerator += velocity * displacement;
    denominator += displacement * displacement;
  }
  if (denominator <= DBL_EPSILON) return 0;
  const double result = numerator / denominator;
  return isfinite(result) ? result : 0;
}

- (void)smoothClipApplyPresentation:(smoothclip::Presentation)presentation {
  _animationPaused = NO;
  [self stopLayerAnimationWithoutCallback];
  [self storeRequestedPresentation:presentation];
  [self applyRequestedClip];
  if (_hasLayout) {
    [self recordInteractiveRect:_normalizedClip
                         radius:_normalizedRadius
             contentTranslation:_normalizedContentTranslation];
  }
}

- (smoothclip::Presentation)smoothClipCurrentPresentation {
  CGFloat visibleRadius = _normalizedRadius;
  const CGRect visibleRect = _activeAnimationId != 0
      ? [self presentationRectWithRadius:&visibleRadius]
      : _normalizedClip;
  CALayer *contentLayer = _activeAnimationId != 0
      ? (CALayer *)_contentContainer.layer.presentationLayer
      : _contentContainer.layer;
  if (contentLayer == nil) contentLayer = _contentContainer.layer;
  const CGAffineTransform transform = contentLayer.affineTransform;
  return {
      {CGRectGetMinX(visibleRect),
       CGRectGetMinY(visibleRect),
       CGRectGetWidth(visibleRect),
       CGRectGetHeight(visibleRect),
       visibleRadius},
      transform.tx,
      transform.ty};
}

- (BOOL)smoothClipIsJoinable {
  // A view without layout reports zero geometry from
  // smoothClipCurrentPresentation and must not be used as a join reference.
  return _hasLayout;
}

- (smoothclip::Presentation)smoothClipFreezePresentation {
  const smoothclip::Presentation visible =
      [self smoothClipCurrentPresentation];
  const CGRect visibleRect = CGRectMake(
      visible.clip.x,
      visible.clip.y,
      visible.clip.width,
      visible.clip.height);
  const CGPoint visibleContentTranslation = CGPointMake(
      visible.contentTranslateX,
      visible.contentTranslateY);
  _animationPaused = NO;
  [self stopLayerAnimationWithoutCallback];
  _requestedClip = visibleRect;
  _requestedRadius = visible.clip.radius;
  _requestedContentTranslation = visibleContentTranslation;
  [self writeLayerRect:visibleRect radius:visible.clip.radius];
  [self writeContentTranslation:visibleContentTranslation];
  [self syncVisibilityForRect:visibleRect];
  [self recordInteractiveRect:visibleRect
                       radius:visible.clip.radius
           contentTranslation:visibleContentTranslation];
  return visible;
}

- (CGRect)presentationRectWithRadius:(CGFloat *)radius {
  CALayer *layer = (CALayer *)_clipContainer.layer.presentationLayer;
  if (layer == nil) layer = _clipContainer.layer;
  const CGRect bounds = layer.bounds;
  const CGPoint position = layer.position;
  if (radius != nullptr) *radius = layer.cornerRadius;
  return CGRectMake(
      position.x - bounds.size.width * layer.anchorPoint.x,
      position.y - bounds.size.height * layer.anchorPoint.y,
      bounds.size.width,
      bounds.size.height);
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
  _ignoreAnimationCallback = NO;
  _activeAnimationId = 0;
  _activeAnimationKind = 0;
  _animationPaused = NO;
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

- (void)installAnimationFromRect:(CGRect)fromRect
                      fromRadius:(CGFloat)fromRadius
          fromContentTranslation:(CGPoint)fromContentTranslation
                          toRect:(CGRect)toRect
                        toRadius:(CGFloat)toRadius
            toContentTranslation:(CGPoint)toContentTranslation
                        duration:(CFTimeInterval)duration {
  const int32_t animationId = _activeAnimationId;
  const NSInteger animationKind = _activeAnimationKind;
  [self stopLayerAnimationWithoutCallback];
  _activeAnimationId = animationId;
  _activeAnimationKind = animationKind;
  // Unhide while any animated frame can show content; an empty-to-empty
  // transition must stay hidden for accessibility.
  if (!CGRectIsEmpty(toRect) || !CGRectIsEmpty(fromRect)) {
    [self setClipContainerHidden:NO];
  }

  CALayer *layer = _clipContainer.layer;
  const CGRect toBounds = toRect;
  const CGPoint fromPosition =
      CGPointMake(CGRectGetMidX(fromRect), CGRectGetMidY(fromRect));
  const CGPoint toPosition =
      CGPointMake(CGRectGetMidX(toRect), CGRectGetMidY(toRect));
  layer.bounds = toBounds;
  layer.position = toPosition;
  layer.cornerRadius = toRadius;
  _contentContainer.layer.affineTransform = CGAffineTransformMakeTranslation(
      toContentTranslation.x,
      toContentTranslation.y);
  _normalizedClip = toRect;
  _normalizedRadius = toRadius;
  _normalizedContentTranslation = toContentTranslation;

  CAAnimationGroup *group = [CAAnimationGroup animation];
  CAAnimationGroup *contentGroup = [CAAnimationGroup animation];
  if (_activeAnimationKind == 1) {
    CAMediaTimingFunction *timing = [CAMediaTimingFunction
        functionWithControlPoints:_timingAnimation.controlPoint1X
                                  :_timingAnimation.controlPoint1Y
                                  :_timingAnimation.controlPoint2X
                                  :_timingAnimation.controlPoint2Y];
    group.animations = @[
      [self basicAnimationForKeyPath:@"bounds"
                           fromValue:[NSValue valueWithCGRect:fromRect]
                             toValue:[NSValue valueWithCGRect:toBounds]
                      timingFunction:timing],
      [self basicAnimationForKeyPath:@"position"
                           fromValue:[NSValue valueWithCGPoint:fromPosition]
                             toValue:[NSValue valueWithCGPoint:toPosition]
                      timingFunction:timing],
      [self basicAnimationForKeyPath:@"cornerRadius"
                           fromValue:@(fromRadius)
                             toValue:@(toRadius)
                      timingFunction:timing],
    ];
    group.duration = duration;
    contentGroup.animations = @[
      [self basicAnimationForKeyPath:@"transform.translation.x"
                           fromValue:@(fromContentTranslation.x)
                             toValue:@(toContentTranslation.x)
                      timingFunction:timing],
      [self basicAnimationForKeyPath:@"transform.translation.y"
                           fromValue:@(fromContentTranslation.y)
                             toValue:@(toContentTranslation.y)
                      timingFunction:timing],
    ];
    contentGroup.duration = duration;
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
    group.animations = @[
      [self springAnimationForKeyPath:@"bounds.origin.x"
                            fromValue:@(fromRect.origin.x)
                              toValue:@(toBounds.origin.x)
                             velocity:velocity
                             duration:springDuration],
      [self springAnimationForKeyPath:@"bounds.origin.y"
                            fromValue:@(fromRect.origin.y)
                              toValue:@(toBounds.origin.y)
                             velocity:velocity
                             duration:springDuration],
      [self springAnimationForKeyPath:@"bounds.size.width"
                            fromValue:@(fromRect.size.width)
                              toValue:@(toBounds.size.width)
                             velocity:velocity
                             duration:springDuration],
      [self springAnimationForKeyPath:@"bounds.size.height"
                            fromValue:@(fromRect.size.height)
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
      [self springAnimationForKeyPath:@"cornerRadius"
                            fromValue:@(fromRadius)
                              toValue:@(toRadius)
                             velocity:velocity
                             duration:springDuration],
    ];
    // A rebuilt spring (layout change, foreground resume) must run its own
    // settling time; clamping to the interrupted run's remaining wall-clock
    // time would truncate the oscillation and snap to the target.
    group.duration = springDuration;
    contentGroup.animations = @[
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
    ];
    contentGroup.duration = springDuration;
  }

  _animationDuration = group.duration;
  _animationStartedAt = CACurrentMediaTime();
  _animationDelegate = [SmoothClipAnimationDelegate new];
  _animationDelegate.view = self;
  _animationDelegate.driverId = _driverId;
  _animationDelegate.animationId = _activeAnimationId;
  group.delegate = _animationDelegate;
  [layer addAnimation:group forKey:@"smoothClip.geometry"];
  [_contentContainer.layer addAnimation:contentGroup
                                 forKey:@"smoothClip.content"];
}

- (void)startAnimationToRequestedGeometryWithDuration:(CFTimeInterval)duration {
  if (!_hasLayout) {
    _pendingAnimationInstall = YES;
    return;
  }
  SmoothNormalizedClipGeometry target;
  if (![self normalizedRequestedGeometry:&target]) return;
  const smoothclip::Presentation current = [self smoothClipCurrentPresentation];
  [self installAnimationFromRect:CGRectMake(
                                     current.clip.x,
                                     current.clip.y,
                                     current.clip.width,
                                     current.clip.height)
                      fromRadius:current.clip.radius
          fromContentTranslation:CGPointMake(
                                     current.contentTranslateX,
                                     current.contentTranslateY)
                          toRect:target.rect
                        toRadius:target.radius
            toContentTranslation:_requestedContentTranslation
                        duration:duration];
}

- (void)smoothClipAnimateTiming:(smoothclip::Presentation)presentation
                       animation:(smoothclip::TimingAnimation)animation
                     animationId:(int32_t)animationId {
  [self storeRequestedPresentation:presentation];
  _timingAnimation = animation;
  _activeAnimationKind = 1;
  _activeAnimationId = animationId;
  [self startAnimationToRequestedGeometryWithDuration:
            MAX(0, animation.durationMs) / 1000.0];
}

- (void)smoothClipAnimateSpring:(smoothclip::Presentation)presentation
                       animation:(smoothclip::SpringAnimation)animation
                     animationId:(int32_t)animationId {
  [self storeRequestedPresentation:presentation];
  _springAnimation = animation;
  if (animation.inheritVelocity) {
    SmoothNormalizedClipGeometry target;
    if ([self normalizedRequestedGeometry:&target]) {
      _springAnimation.initialVelocity =
          [self inheritedVelocityToRect:target.rect
                                  radius:target.radius
                      contentTranslation:_requestedContentTranslation];
    } else {
      _springAnimation.initialVelocity = 0;
    }
  }
  _activeAnimationKind = 2;
  _activeAnimationId = animationId;
  [self startAnimationToRequestedGeometryWithDuration:0];
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

- (void)smoothClipAnimateKeyframes:(smoothclip::Presentation)presentation
                          keyframes:(const std::vector<smoothclip::Keyframe> &)keyframes
                          durationMs:(double)durationMs
                         animationId:(int32_t)animationId {
  if (keyframes.size() < 2) return;
  [self storeRequestedPresentation:presentation];
  _activeAnimationKind = 3;
  _activeAnimationId = animationId;
  if (!_hasLayout) {
    _pendingAnimationInstall = YES;
    return;
  }
  [self stopLayerAnimationWithoutCallback];
  _activeAnimationKind = 3;
  _activeAnimationId = animationId;

  const NSUInteger frameCount = keyframes.size();
  const CGSize hostSize = self.bounds.size;
  NSMutableArray<NSNumber *> *times =
      [NSMutableArray arrayWithCapacity:frameCount];
  NSMutableArray *boundsValues = [NSMutableArray arrayWithCapacity:frameCount];
  NSMutableArray *positionValues =
      [NSMutableArray arrayWithCapacity:frameCount];
  NSMutableArray *radiusValues = [NSMutableArray arrayWithCapacity:frameCount];
  NSMutableArray *translateXValues =
      [NSMutableArray arrayWithCapacity:frameCount];
  NSMutableArray *translateYValues =
      [NSMutableArray arrayWithCapacity:frameCount];
  for (const smoothclip::Keyframe &frame : keyframes) {
    SmoothNormalizedClipGeometry normalized;
    if (!SmoothClipNormalizeGeometry(
            frame.presentation.clip.x,
            frame.presentation.clip.y,
            frame.presentation.clip.width,
            frame.presentation.clip.height,
            frame.presentation.clip.radius,
            hostSize,
            &normalized)) return;
    [times addObject:@(frame.offset)];
    [boundsValues addObject:[NSValue valueWithCGRect:normalized.rect]];
    [positionValues addObject:[NSValue valueWithCGPoint:CGPointMake(
        CGRectGetMidX(normalized.rect), CGRectGetMidY(normalized.rect))]];
    [radiusValues addObject:@(normalized.radius)];
    [translateXValues addObject:@(frame.presentation.contentTranslateX)];
    [translateYValues addObject:@(frame.presentation.contentTranslateY)];
  }

  SmoothNormalizedClipGeometry target;
  if (![self normalizedRequestedGeometry:&target]) return;
  [self writeLayerRect:target.rect radius:target.radius];
  [self writeContentTranslation:_requestedContentTranslation];
  [self setClipContainerHidden:NO];

  CAAnimationGroup *group = [CAAnimationGroup animation];
  group.animations = @[
    [self keyframeAnimationForKeyPath:@"bounds"
                               values:boundsValues
                             keyTimes:times],
    [self keyframeAnimationForKeyPath:@"position"
                               values:positionValues
                             keyTimes:times],
    [self keyframeAnimationForKeyPath:@"cornerRadius"
                               values:radiusValues
                             keyTimes:times],
  ];
  group.duration = MAX(0, durationMs) / 1000.0;
  CAAnimationGroup *contentGroup = [CAAnimationGroup animation];
  contentGroup.animations = @[
    [self keyframeAnimationForKeyPath:@"transform.translation.x"
                               values:translateXValues
                             keyTimes:times],
    [self keyframeAnimationForKeyPath:@"transform.translation.y"
                               values:translateYValues
                             keyTimes:times],
  ];
  contentGroup.duration = group.duration;

  _animationDuration = group.duration;
  _animationStartedAt = CACurrentMediaTime();
  _animationDelegate = [SmoothClipAnimationDelegate new];
  _animationDelegate.view = self;
  _animationDelegate.driverId = _driverId;
  _animationDelegate.animationId = _activeAnimationId;
  group.delegate = _animationDelegate;
  [_clipContainer.layer addAnimation:group forKey:@"smoothClip.geometry"];
  [_contentContainer.layer addAnimation:contentGroup
                                 forKey:@"smoothClip.content"];
}

- (void)smoothClipCancelAnimationUsingTarget:(BOOL)useTarget {
  if (_activeAnimationId == 0) return;
  const smoothclip::Presentation visible =
      [self smoothClipCurrentPresentation];
  const CGRect visibleRect = CGRectMake(
      visible.clip.x,
      visible.clip.y,
      visible.clip.width,
      visible.clip.height);
  const CGPoint visibleContentTranslation = CGPointMake(
      visible.contentTranslateX,
      visible.contentTranslateY);
  _animationPaused = NO;
  [self stopLayerAnimationWithoutCallback];
  if (useTarget) {
    [self applyRequestedClip];
  } else {
    _requestedClip = visibleRect;
    _requestedRadius = visible.clip.radius;
    _requestedContentTranslation = visibleContentTranslation;
    [self writeLayerRect:visibleRect radius:visible.clip.radius];
    [self writeContentTranslation:visibleContentTranslation];
    [self syncVisibilityForRect:visibleRect];
    [self recordInteractiveRect:visibleRect
                         radius:visible.clip.radius
             contentTranslation:visibleContentTranslation];
  }
}

- (void)applicationWillResignActive {
  if (_activeAnimationId == 0 || _animationPaused) return;
  const smoothclip::Presentation visible =
      [self smoothClipCurrentPresentation];
  _pausedRect = CGRectMake(
      visible.clip.x,
      visible.clip.y,
      visible.clip.width,
      visible.clip.height);
  _pausedRadius = visible.clip.radius;
  _pausedContentTranslation = CGPointMake(
      visible.contentTranslateX,
      visible.contentTranslateY);
  _pausedRemaining = MAX(
      0, _animationDuration - (CACurrentMediaTime() - _animationStartedAt));
  const int32_t animationId = _activeAnimationId;
  const NSInteger animationKind = _activeAnimationKind;
  [self stopLayerAnimationWithoutCallback];
  _activeAnimationId = animationId;
  _activeAnimationKind = animationKind;
  [self writeLayerRect:_pausedRect radius:_pausedRadius];
  [self writeContentTranslation:_pausedContentTranslation];
  _animationPaused = YES;
}

- (void)applicationDidBecomeActive {
  if (!_animationPaused || _activeAnimationId == 0) return;
  _animationPaused = NO;
  SmoothNormalizedClipGeometry target;
  if ([self normalizedRequestedGeometry:&target]) {
    if (_activeAnimationKind == 3) {
      _activeAnimationKind = 1;
      _timingAnimation = {
          _pausedRemaining * 1000.0, 0, 0, 1, 1, 2};
    }
    [self installAnimationFromRect:_pausedRect
                        fromRadius:_pausedRadius
            fromContentTranslation:_pausedContentTranslation
                            toRect:target.rect
                          toRadius:target.radius
              toContentTranslation:_requestedContentTranslation
                          duration:_pausedRemaining];
  }
}

- (void)smoothClipAnimationDidStopWithDriverId:(uint64_t)driverId
                                    animationId:(int32_t)animationId
                                       finished:(BOOL)finished {
  if (_ignoreAnimationCallback || animationId != _activeAnimationId) return;
  _activeAnimationId = 0;
  _activeAnimationKind = 0;
  _animationPaused = NO;
  _animationDelegate = nil;
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
  const smoothclip::Presentation initial{
      {newProps.initialClipX,
       newProps.initialClipY,
       newProps.initialClipWidth,
       newProps.initialClipHeight,
       newProps.initialClipRadius},
      newProps.initialContentTranslateX,
      newProps.initialContentTranslateY};

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
  if (!_hasLayout && _pendingAnimationInstall && _driverId != 0) {
    // A native animation install arrived before the first layout. Join it now
    // through the registry so it starts from live presentation geometry with
    // the true remaining duration instead of jumping to the target.
    [super updateLayoutMetrics:layoutMetrics oldLayoutMetrics:oldLayoutMetrics];
    _hasLayout = YES;
    _pendingAnimationInstall = NO;
    [self layoutContentContainer];
    if (!smoothclip::joinActiveAnimation(_driverId, self)) {
      // The animation finished or was cancelled while awaiting layout.
      _activeAnimationId = 0;
      _activeAnimationKind = 0;
      [self applyRequestedClip];
    }
    return;
  }
  CGFloat visibleRadius = 0;
  const BOOL wasAnimating = _activeAnimationId != 0;
  const smoothclip::Presentation visible = wasAnimating
      ? [self smoothClipCurrentPresentation]
      : smoothclip::Presentation{{0, 0, 0, 0, 0}, 0, 0};
  const CGRect visibleRect = CGRectMake(
      visible.clip.x,
      visible.clip.y,
      visible.clip.width,
      visible.clip.height);
  visibleRadius = visible.clip.radius;
  const CGPoint visibleContentTranslation = CGPointMake(
      visible.contentTranslateX,
      visible.contentTranslateY);
  const CFTimeInterval remaining = wasAnimating
      ? MAX(0, _animationDuration -
                   (CACurrentMediaTime() - _animationStartedAt))
      : 0;

  [super updateLayoutMetrics:layoutMetrics oldLayoutMetrics:oldLayoutMetrics];
  _hasLayout = YES;
  [self layoutContentContainer];
  if (wasAnimating && _animationPaused) {
    SmoothNormalizedClipGeometry paused;
    if (SmoothClipNormalizeGeometry(
            CGRectGetMinX(_pausedRect),
            CGRectGetMinY(_pausedRect),
            CGRectGetWidth(_pausedRect),
            CGRectGetHeight(_pausedRect),
            _pausedRadius,
            self.bounds.size,
            &paused)) {
      _pausedRect = paused.rect;
      _pausedRadius = paused.radius;
      [self writeLayerRect:paused.rect radius:paused.radius];
    }
  } else if (wasAnimating) {
    const int32_t animationId = _activeAnimationId;
    const NSInteger animationKind = _activeAnimationKind;
    [self stopLayerAnimationWithoutCallback];
    _activeAnimationId = animationId;
    _activeAnimationKind = animationKind;
    if (_activeAnimationKind == 3) {
      _activeAnimationKind = 1;
      _timingAnimation = {remaining * 1000.0, 0, 0, 1, 1, 2};
    }
    SmoothNormalizedClipGeometry current;
    SmoothClipNormalizeGeometry(
        CGRectGetMinX(visibleRect),
        CGRectGetMinY(visibleRect),
        CGRectGetWidth(visibleRect),
        CGRectGetHeight(visibleRect),
        visibleRadius,
        self.bounds.size,
        &current);
    SmoothNormalizedClipGeometry target;
    if ([self normalizedRequestedGeometry:&target]) {
      [self installAnimationFromRect:current.rect
                          fromRadius:current.radius
              fromContentTranslation:visibleContentTranslation
                              toRect:target.rect
                            toRadius:target.radius
                toContentTranslation:_requestedContentTranslation
                            duration:remaining];
    }
  } else {
    [self applyRequestedClip];
  }
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
  if (![super pointInside:point withEvent:event]) return NO;
  CGFloat radius = 0;
  const CGRect clip = _activeAnimationId != 0
      ? [self presentationRectWithRadius:&radius]
      : _normalizedClip;
  if (_activeAnimationId == 0) radius = _normalizedRadius;
  if (CGRectIsEmpty(clip) || !CGRectContainsPoint(clip, point)) return NO;
  if (radius <= 0) return YES;

  const CGFloat innerLeft = CGRectGetMinX(clip) + radius;
  const CGFloat innerRight = CGRectGetMaxX(clip) - radius;
  const CGFloat innerTop = CGRectGetMinY(clip) + radius;
  const CGFloat innerBottom = CGRectGetMaxY(clip) - radius;
  if ((point.x >= innerLeft && point.x <= innerRight) ||
      (point.y >= innerTop && point.y <= innerBottom)) {
    return YES;
  }

  const CGFloat centerX = point.x < innerLeft ? innerLeft : innerRight;
  const CGFloat centerY = point.y < innerTop ? innerTop : innerBottom;
  const CGFloat dx = point.x - centerX;
  const CGFloat dy = point.y - centerY;
  return dx * dx + dy * dy <= radius * radius;
}

#pragma mark - Legacy native command (Android parity and benchmark baseline)

- (void)handleCommand:(const NSString *)commandName args:(const NSArray *)args {
  RCTSmoothClipViewHandleCommand(self, commandName, args);
}

- (void)setClipGeometry:(double)x
                       y:(double)y
                   width:(double)width
                  height:(double)height
                  radius:(double)radius {
  _commandIsAuthoritative = YES;
  [self smoothClipApplyPresentation:
      {{x, y, width, height, radius}, 0, 0}];
}

- (void)setClipPresentation:(double)x
                           y:(double)y
                       width:(double)width
                      height:(double)height
                      radius:(double)radius
           contentTranslateX:(double)contentTranslateX
           contentTranslateY:(double)contentTranslateY {
  _commandIsAuthoritative = YES;
  [self smoothClipApplyPresentation:
      {{x, y, width, height, radius},
       contentTranslateX,
       contentTranslateY}];
}

- (void)prepareForRecycle {
  if (_driverId != 0) {
    smoothclip::unregisterView(_driverId, self);
    _driverId = 0;
  }
  [self stopLayerAnimationWithoutCallback];
  _pendingAnimationInstall = NO;
  _animationPaused = NO;
  _hasPreviousInteractiveSample = NO;
  _hasInteractiveSample = NO;
  [super prepareForRecycle];
  _requestedClip = CGRectZero;
  _normalizedClip = CGRectZero;
  _requestedRadius = 0;
  _normalizedRadius = 0;
  _requestedContentTranslation = CGPointZero;
  _normalizedContentTranslation = CGPointZero;
  _hasLayout = NO;
  _commandIsAuthoritative = NO;

  CALayer *layer = _clipContainer.layer;
  layer.bounds = CGRectZero;
  layer.position = CGPointZero;
  layer.cornerRadius = 0;
  _contentContainer.layer.affineTransform = CGAffineTransformIdentity;
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
