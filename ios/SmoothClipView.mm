#import "SmoothClipView.h"
#import "SmoothClipGeometry.h"

#import <QuartzCore/QuartzCore.h>
#import <React/RCTConversions.h>
#import <React/RCTFabricComponentsPlugins.h>
#import <react/renderer/components/SmoothClipViewSpec/ComponentDescriptors.h>
#import <react/renderer/components/SmoothClipViewSpec/Props.h>
#import <react/renderer/components/SmoothClipViewSpec/RCTComponentViewHelpers.h>

using namespace facebook::react;

@interface SmoothClipView () <RCTSmoothClipViewViewProtocol>
@end

@implementation SmoothClipView {
  UIView *_clipContainer;
  CGRect _requestedClip;
  CGRect _normalizedClip;
  CGFloat _requestedRadius;
  CGFloat _normalizedRadius;
  BOOL _hasLayout;
  BOOL _commandIsAuthoritative;
}

+ (ComponentDescriptorProvider)componentDescriptorProvider {
  return concreteComponentDescriptorProvider<SmoothClipViewComponentDescriptor>();
}

+ (BOOL)shouldBeRecycled {
  return NO;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if (self = [super initWithFrame:frame]) {
    static const auto defaultProps =
        std::make_shared<const SmoothClipViewProps>();
    _props = defaultProps;

    _clipContainer = [[UIView alloc] initWithFrame:CGRectZero];
    _clipContainer.clipsToBounds = YES;
    _clipContainer.hidden = YES;
    _clipContainer.accessibilityElementsHidden = YES;
    [self addSubview:_clipContainer];

    _requestedClip = CGRectZero;
    _normalizedClip = CGRectZero;
    _requestedRadius = 0;
    _normalizedRadius = 0;
    _hasLayout = NO;
    _commandIsAuthoritative = NO;
  }
  return self;
}

- (void)mountChildComponentView:(UIView<RCTComponentViewProtocol> *)childComponentView
                          index:(NSInteger)index {
  NSAssert(childComponentView.superview == nil,
           @"SmoothClipView attempted to mount an already-mounted child");
  [_clipContainer insertSubview:childComponentView atIndex:index];
}

- (void)unmountChildComponentView:(UIView<RCTComponentViewProtocol> *)childComponentView
                            index:(NSInteger)index {
  NSAssert(childComponentView.superview == _clipContainer,
           @"SmoothClipView attempted to unmount a child from another parent");
  NSAssert(index < _clipContainer.subviews.count &&
               _clipContainer.subviews[index] == childComponentView,
           @"SmoothClipView child index mismatch");
  [childComponentView removeFromSuperview];
}

- (void)setRequestedClipX:(CGFloat)x
                         y:(CGFloat)y
                    width:(CGFloat)width
                   height:(CGFloat)height
                   radius:(CGFloat)radius {
  if (!isfinite(x) || !isfinite(y) || !isfinite(width) ||
      !isfinite(height) || !isfinite(radius)) {
    return;
  }

  _requestedClip = CGRectMake(x, y, MAX(0, width), MAX(0, height));
  _requestedRadius = MAX(0, radius);
  [self applyRequestedClip];
}

- (void)applyRequestedClip {
  if (!_hasLayout) {
    return;
  }

  const CGFloat hostWidth = MAX(0, self.bounds.size.width);
  const CGFloat hostHeight = MAX(0, self.bounds.size.height);
  SmoothNormalizedClipGeometry geometry;
  if (!SmoothClipNormalizeGeometry(
          CGRectGetMinX(_requestedClip),
          CGRectGetMinY(_requestedClip),
          CGRectGetWidth(_requestedClip),
          CGRectGetHeight(_requestedClip),
          _requestedRadius,
          CGSizeMake(hostWidth, hostHeight),
          &geometry)) {
    return;
  }

  const BOOL rectChanged = !CGRectEqualToRect(_normalizedClip, geometry.rect);
  const BOOL radiusChanged = _normalizedRadius != geometry.radius;
  const BOOL isEmpty = CGRectIsEmpty(geometry.rect);
  const BOOL hiddenChanged = _clipContainer.hidden != isEmpty;
  const BOOL accessibilityChanged =
      _clipContainer.accessibilityElementsHidden != isEmpty;

  _normalizedClip = geometry.rect;
  _normalizedRadius = geometry.radius;
  if (!rectChanged && !radiusChanged && !hiddenChanged &&
      !accessibilityChanged) {
    return;
  }

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  if (rectChanged) {
    _clipContainer.bounds = _normalizedClip;
    _clipContainer.center = CGPointMake(
        CGRectGetMidX(_normalizedClip), CGRectGetMidY(_normalizedClip));
  }
  if (radiusChanged) {
    _clipContainer.layer.cornerRadius = _normalizedRadius;
  }
  if (hiddenChanged) {
    _clipContainer.hidden = isEmpty;
  }
  if (accessibilityChanged) {
    _clipContainer.accessibilityElementsHidden = isEmpty;
  }
  [CATransaction commit];
}

- (void)updateProps:(const Props::Shared &)props
            oldProps:(const Props::Shared &)oldProps {
  const auto &newProps =
      *std::static_pointer_cast<const SmoothClipViewProps>(props);
  [super updateProps:props oldProps:oldProps];

  if (!_commandIsAuthoritative) {
    [self setRequestedClipX:newProps.initialClipX
                         y:newProps.initialClipY
                     width:newProps.initialClipWidth
                    height:newProps.initialClipHeight
                    radius:newProps.initialClipRadius];
  }
}

- (void)updateLayoutMetrics:(const LayoutMetrics &)layoutMetrics
            oldLayoutMetrics:(const LayoutMetrics &)oldLayoutMetrics {
  [super updateLayoutMetrics:layoutMetrics oldLayoutMetrics:oldLayoutMetrics];
  _hasLayout = YES;
  [self applyRequestedClip];
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
  if (![super pointInside:point withEvent:event] ||
      CGRectIsEmpty(_normalizedClip) ||
      !CGRectContainsPoint(_normalizedClip, point)) {
    return NO;
  }

  const CGFloat radius = _normalizedRadius;
  if (radius <= 0) {
    return YES;
  }

  const CGFloat innerLeft = CGRectGetMinX(_normalizedClip) + radius;
  const CGFloat innerRight = CGRectGetMaxX(_normalizedClip) - radius;
  const CGFloat innerTop = CGRectGetMinY(_normalizedClip) + radius;
  const CGFloat innerBottom = CGRectGetMaxY(_normalizedClip) - radius;
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

#pragma mark - Native commands

- (void)handleCommand:(const NSString *)commandName args:(const NSArray *)args {
  RCTSmoothClipViewHandleCommand(self, commandName, args);
}

- (void)setClipGeometry:(double)x
                       y:(double)y
                   width:(double)width
                  height:(double)height
                  radius:(double)radius {
  _commandIsAuthoritative = YES;
  [self setRequestedClipX:x y:y width:width height:height radius:radius];
}

- (void)prepareForRecycle {
  [super prepareForRecycle];
  _requestedClip = CGRectZero;
  _normalizedClip = CGRectZero;
  _requestedRadius = 0;
  _normalizedRadius = 0;
  _hasLayout = NO;
  _commandIsAuthoritative = NO;

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  _clipContainer.bounds = CGRectZero;
  _clipContainer.center = CGPointZero;
  _clipContainer.layer.cornerRadius = 0;
  _clipContainer.hidden = YES;
  _clipContainer.accessibilityElementsHidden = YES;
  [CATransaction commit];
}

@end
