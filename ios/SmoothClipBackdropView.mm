#import "SmoothClipBackdropView.h"

#import "SmoothClipViewRegistry.h"

#include "SmoothClipAnimationCurve.h"

#import <QuartzCore/QuartzCore.h>
#import <React/RCTFabricComponentsPlugins.h>
#import <react/renderer/components/SmoothClipViewSpec/ComponentDescriptors.h>
#import <react/renderer/components/SmoothClipViewSpec/Props.h>
#import <react/renderer/components/SmoothClipViewSpec/RCTComponentViewHelpers.h>

#include <algorithm>
#include <cmath>

using namespace facebook::react;

static NSString *const kSmoothClipBackdropAnimationKey = @"smoothClip.backdrop";

@interface SmoothClipBackdropContentView : UIView
@end

@implementation SmoothClipBackdropContentView

- (id<CAAction>)actionForLayer:(CALayer *)layer forKey:(NSString *)event {
  // The registry drives the translation explicitly, by a model write or by
  // the animations installed below; no implicit action per frame.
  return (id<CAAction>)[NSNull null];
}

@end

@implementation SmoothClipBackdropView {
  SmoothClipBackdropContentView *_content;
  uint64_t _driverId;
  CGPoint _translation;
  BOOL _animating;
}

+ (ComponentDescriptorProvider)componentDescriptorProvider {
  return concreteComponentDescriptorProvider<
      SmoothClipBackdropViewComponentDescriptor>();
}

+ (BOOL)shouldBeRecycled {
  return NO;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if (self = [super initWithFrame:frame]) {
    static const auto defaultProps =
        std::make_shared<const SmoothClipBackdropViewProps>();
    _props = defaultProps;
    _content = [[SmoothClipBackdropContentView alloc] initWithFrame:self.bounds];
    _content.autoresizesSubviews = NO;
    [self addSubview:_content];
    _driverId = 0;
    _translation = CGPointZero;
    _animating = NO;
  }
  return self;
}

- (void)dealloc {
  if (_driverId != 0) {
    smoothclip::unregisterBackdropView(_driverId, self);
  }
}

- (void)mountChildComponentView:(UIView<RCTComponentViewProtocol> *)childComponentView
                          index:(NSInteger)index {
  NSAssert(childComponentView.superview == nil,
           @"SmoothClipBackdropView attempted to mount an already-mounted child");
  [_content insertSubview:childComponentView atIndex:index];
}

- (void)unmountChildComponentView:(UIView<RCTComponentViewProtocol> *)childComponentView
                            index:(NSInteger)index {
  NSAssert(childComponentView.superview == _content,
           @"SmoothClipBackdropView attempted to unmount a child from another parent");
  [childComponentView removeFromSuperview];
}

- (void)updateLayoutMetrics:(const LayoutMetrics &)layoutMetrics
           oldLayoutMetrics:(const LayoutMetrics &)oldLayoutMetrics {
  [super updateLayoutMetrics:layoutMetrics oldLayoutMetrics:oldLayoutMetrics];
  _content.frame = self.bounds;
}

- (void)updateProps:(const Props::Shared &)props
           oldProps:(const Props::Shared &)oldProps {
  const auto &newProps =
      *std::static_pointer_cast<const SmoothClipBackdropViewProps>(props);
  [super updateProps:props oldProps:oldProps];
  const uint64_t nextDriverId =
      isfinite(newProps.driverId) && newProps.driverId > 0
      ? static_cast<uint64_t>(newProps.driverId)
      : 0;
  if (nextDriverId == _driverId) return;
  if (_driverId != 0) {
    smoothclip::unregisterBackdropView(_driverId, self);
  }
  _driverId = nextDriverId;
  if (_driverId != 0) {
    smoothclip::registerBackdropView(_driverId, self);
  }
}

- (void)prepareForRecycle {
  if (_driverId != 0) {
    smoothclip::unregisterBackdropView(_driverId, self);
    _driverId = 0;
  }
  [self stopBackdropAnimation];
  [self writeTranslation:CGPointZero];
  [super prepareForRecycle];
}

// MARK: - Registry hooks

- (void)writeTranslation:(CGPoint)translation {
  _translation = translation;
  _content.layer.transform =
      CATransform3DMakeTranslation(translation.x, translation.y, 0);
}

- (void)stopBackdropAnimation {
  if (!_animating) return;
  [_content.layer removeAnimationForKey:kSmoothClipBackdropAnimationKey];
  _animating = NO;
}

- (CGPoint)smoothClipBackdropCurrentTranslation {
  CALayer *layer = _animating ? _content.layer.presentationLayer : nil;
  if (layer == nil) return _translation;
  const CATransform3D transform = layer.transform;
  return CGPointMake(transform.m41, transform.m42);
}

- (void)smoothClipApplyBackdrop:(CGPoint)translation {
  [self stopBackdropAnimation];
  [self writeTranslation:translation];
}

- (void)installBackdropGroup:(CAAnimationGroup *)group
             sharedBeginTime:(CFTimeInterval)sharedBeginTime {
  if (sharedBeginTime <= 0) sharedBeginTime = CACurrentMediaTime();
  // The clip's epoch, translated into this layer's clock: a stamped epoch
  // may sit up to one frame ahead of the commit, and until it arrives the
  // run presents its first frame rather than the target the model holds.
  group.beginTime = [_content.layer convertTime:sharedBeginTime fromLayer:nil];
  group.fillMode = kCAFillModeBackwards;
  [_content.layer addAnimation:group forKey:kSmoothClipBackdropAnimationKey];
  _animating = YES;
}

- (BOOL)smoothClipAnimateBackdropTo:(CGPoint)target
                             timing:(smoothclip::TimingAnimation)timing
                    sharedBeginTime:(CFTimeInterval)sharedBeginTime {
  const CGPoint from = [self smoothClipBackdropCurrentTranslation];
  [self stopBackdropAnimation];
  [self writeTranslation:target];
  if (self.window == nil) return NO;
  CAMediaTimingFunction *function = [CAMediaTimingFunction
      functionWithControlPoints:timing.controlPoint1X
                               :timing.controlPoint1Y
                               :timing.controlPoint2X
                               :timing.controlPoint2Y];
  CABasicAnimation *x =
      [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
  x.fromValue = @(from.x);
  x.toValue = @(target.x);
  x.timingFunction = function;
  CABasicAnimation *y =
      [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
  y.fromValue = @(from.y);
  y.toValue = @(target.y);
  y.timingFunction = function;
  CAAnimationGroup *group = [CAAnimationGroup animation];
  group.animations = @[ x, y ];
  group.duration = std::max(0.0, timing.durationMs) / 1000.0;
  [self installBackdropGroup:group sharedBeginTime:sharedBeginTime];
  return YES;
}

- (BOOL)smoothClipAnimateBackdropTo:(CGPoint)target
                             spring:(smoothclip::SpringAnimation)spring
                    sharedBeginTime:(CFTimeInterval)sharedBeginTime {
  const CGPoint from = [self smoothClipBackdropCurrentTranslation];
  [self stopBackdropAnimation];
  [self writeTranslation:target];
  if (self.window == nil) return NO;
  // The same normalized trajectory and settling rule as the clip host, so
  // both layers stop in the same frame.
  smoothclip::ScalarSpringState state{0, spring.initialVelocity};
  constexpr double step = 1.0 / 120.0;
  double duration = 0;
  while (duration < 10.0 &&
         smoothclip::relativeSpringEnergy(state, spring) >
             spring.energyThreshold) {
    state = smoothclip::advanceScalarSpring(state, spring, step);
    duration += step;
  }
  const auto animation = [&](NSString *keyPath, double fromValue, double toValue) {
    CASpringAnimation *result = [CASpringAnimation animationWithKeyPath:keyPath];
    result.fromValue = @(fromValue);
    result.toValue = @(toValue);
    result.mass = spring.mass;
    result.stiffness = spring.stiffness;
    result.damping = spring.damping;
    result.initialVelocity = spring.initialVelocity;
    result.duration = duration;
    return result;
  };
  CAAnimationGroup *group = [CAAnimationGroup animation];
  group.animations = @[
    animation(@"transform.translation.x", from.x, target.x),
    animation(@"transform.translation.y", from.y, target.y),
  ];
  group.duration = duration;
  [self installBackdropGroup:group sharedBeginTime:sharedBeginTime];
  return YES;
}

- (void)smoothClipCancelBackdropUsingTarget:(BOOL)useTarget {
  if (!_animating) return;
  const CGPoint visible = [self smoothClipBackdropCurrentTranslation];
  [self stopBackdropAnimation];
  if (!useTarget) [self writeTranslation:visible];
}

- (BOOL)smoothClipPauseBackdropAtMediaTime:(CFTimeInterval)mediaTime {
  CAAnimation *installed =
      [_content.layer animationForKey:kSmoothClipBackdropAnimationKey];
  if (!_animating || installed == nil) return NO;
  CAAnimation *paused = [installed copy];
  const CFTimeInterval localNow =
      [_content.layer convertTime:mediaTime fromLayer:nil];
  paused.speed = 0;
  paused.timeOffset = std::clamp(
      localNow - installed.beginTime, (CFTimeInterval)0, installed.duration);
  paused.beginTime = 0;
  [_content.layer removeAnimationForKey:kSmoothClipBackdropAnimationKey];
  [_content.layer addAnimation:paused forKey:kSmoothClipBackdropAnimationKey];
  return YES;
}

- (BOOL)smoothClipResumeBackdropAtMediaTime:(CFTimeInterval)mediaTime
                                  catchUpBy:(CFTimeInterval)catchUp {
  CAAnimation *installed =
      [_content.layer animationForKey:kSmoothClipBackdropAnimationKey];
  if (!_animating || installed == nil) return NO;
  CAAnimation *resumed = [installed copy];
  const CFTimeInterval localNow =
      [_content.layer convertTime:mediaTime fromLayer:nil];
  const CFTimeInterval resumedTime = std::min(
      installed.duration,
      std::max((CFTimeInterval)0, installed.timeOffset + catchUp));
  resumed.speed = 1;
  resumed.timeOffset = 0;
  resumed.beginTime = localNow - resumedTime;
  [_content.layer removeAnimationForKey:kSmoothClipBackdropAnimationKey];
  [_content.layer addAnimation:resumed forKey:kSmoothClipBackdropAnimationKey];
  return YES;
}

@end
