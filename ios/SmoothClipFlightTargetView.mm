#import "SmoothClipFlightTargetView.h"

#import "SmoothClipFlight.h"

#import <React/RCTFabricComponentsPlugins.h>
#import <react/renderer/components/SmoothClipViewSpec/ComponentDescriptors.h>
#import <react/renderer/components/SmoothClipViewSpec/Props.h>
#import <react/renderer/components/SmoothClipViewSpec/RCTComponentViewHelpers.h>

using namespace facebook::react;

@interface SmoothClipFlightTargetContentView : UIView
@end

@implementation SmoothClipFlightTargetContentView
// Hiding and revealing happen inside the flight's own transaction; never
// animate them implicitly.
- (id<CAAction>)actionForLayer:(CALayer *)layer forKey:(NSString *)event {
  return (id<CAAction>)[NSNull null];
}
@end

@implementation SmoothClipFlightTargetView {
  SmoothClipFlightTargetContentView *_content;
  NSString *_flightTag;
  BOOL _flightReady;
  BOOL _flightCovered;
  BOOL _transitionObserved;
}

+ (ComponentDescriptorProvider)componentDescriptorProvider {
  return concreteComponentDescriptorProvider<
      SmoothClipFlightTargetComponentDescriptor>();
}

- (instancetype)initWithFrame:(CGRect)frame {
  if (self = [super initWithFrame:frame]) {
    static const auto defaultProps =
        std::make_shared<const SmoothClipFlightTargetProps>();
    _props = defaultProps;
    _content = [[SmoothClipFlightTargetContentView alloc]
        initWithFrame:self.bounds];
    _content.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_content];
    _flightTag = @"";
    _flightReady = YES;
    _flightCovered = NO;
  }
  return self;
}

- (void)dealloc {
  if (_flightTag.length > 0) {
    NSString *tag = _flightTag;
    _flightTag = @"";
    [[SmoothClipFlightCoordinator shared] target:self didChangeTagFrom:tag];
  }
}

- (NSString *)flightTag {
  return _flightTag;
}

- (BOOL)flightReady {
  return _flightReady;
}

- (BOOL)flightCovered {
  return _flightCovered;
}

- (void)setFlightCovered:(BOOL)covered {
  if (_flightCovered == covered) return;
  _flightCovered = covered;
  _content.hidden = covered;
  _content.accessibilityElementsHidden = covered;
}

- (BOOL)flightInTransition {
  return SmoothClipViewIsInTransition(self);
}

- (void)updateProps:(const Props::Shared &)props
           oldProps:(const Props::Shared &)oldProps {
  const auto &newProps =
      *std::static_pointer_cast<const SmoothClipFlightTargetProps>(props);
  [super updateProps:props oldProps:oldProps];
  NSString *tag = [NSString stringWithUTF8String:newProps.flightTag.c_str()] ?: @"";
  const BOOL ready = newProps.ready;
  const BOOL tagChanged = ![tag isEqualToString:_flightTag];
  const BOOL readyChanged = ready != _flightReady;
  _flightReady = ready;
  if (tagChanged) {
    NSString *oldTag = _flightTag;
    _flightTag = [tag copy];
    [[SmoothClipFlightCoordinator shared] target:self didChangeTagFrom:oldTag];
  } else if (readyChanged) {
    [[SmoothClipFlightCoordinator shared] targetStateDidChange:self];
  }
}

- (void)didMoveToWindow {
  [super didMoveToWindow];
  [[SmoothClipFlightCoordinator shared] targetStateDidChange:self];
  // A landing that waits for this target's screen transition resumes when the
  // transition completes.
  if (self.window != nil && !_transitionObserved) {
    __weak SmoothClipFlightTargetView *weakSelf = self;
    _transitionObserved = SmoothClipObserveTransitionEnd(self, ^{
      SmoothClipFlightTargetView *strongSelf = weakSelf;
      if (strongSelf == nil) return;
      strongSelf->_transitionObserved = NO;
      [[SmoothClipFlightCoordinator shared] targetStateDidChange:strongSelf];
    }) != nil;
  }
}

- (void)mountChildComponentView:(UIView<RCTComponentViewProtocol> *)childComponentView
                          index:(NSInteger)index {
  [_content insertSubview:childComponentView atIndex:index];
}

- (void)unmountChildComponentView:(UIView<RCTComponentViewProtocol> *)childComponentView
                            index:(NSInteger)index {
  [childComponentView removeFromSuperview];
}

- (void)prepareForRecycle {
  if (_flightTag.length > 0) {
    NSString *tag = _flightTag;
    _flightTag = @"";
    [[SmoothClipFlightCoordinator shared] target:self didChangeTagFrom:tag];
  }
  self.flightCovered = NO;
  _flightReady = YES;
  [super prepareForRecycle];
}

@end

Class<RCTComponentViewProtocol> SmoothClipFlightTargetCls(void) {
  return SmoothClipFlightTargetView.class;
}
