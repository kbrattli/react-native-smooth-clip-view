#import "SmoothClipFlight.h"

#import "SmoothClipFlightTargetView.h"

#import <objc/runtime.h>

static const void *kSmoothClipFlightLayerKey = &kSmoothClipFlightLayerKey;

UIViewController *SmoothClipOwningViewController(UIView *view) {
  UIResponder *responder = view;
  while (responder != nil && ![responder isKindOfClass:UIViewController.class]) {
    responder = responder.nextResponder;
  }
  return (UIViewController *)responder;
}

// Transitions whose completion has run. UIKit can still report a coordinator
// from inside its completion blocks; a landing evaluated there must not wait
// for the transition that just ended.
static NSHashTable *SmoothClipEndedTransitions(void) {
  static NSHashTable *ended;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    ended = [NSHashTable weakObjectsHashTable];
  });
  return ended;
}

id<UIViewControllerTransitionCoordinator> SmoothClipViewTransitionCoordinator(
    UIView *view) {
  UIViewController *controller = SmoothClipOwningViewController(view);
  while (controller != nil) {
    id<UIViewControllerTransitionCoordinator> coordinator =
        controller.transitionCoordinator;
    if (coordinator != nil &&
        ![SmoothClipEndedTransitions() containsObject:coordinator]) {
      return coordinator;
    }
    controller = controller.parentViewController;
  }
  return nil;
}

BOOL SmoothClipViewIsInTransition(UIView *view) {
  return SmoothClipViewTransitionCoordinator(view) != nil;
}

id<UIViewControllerTransitionCoordinator> SmoothClipObserveTransitionEnd(
    UIView *view,
    dispatch_block_t block) {
  id<UIViewControllerTransitionCoordinator> coordinator =
      SmoothClipViewTransitionCoordinator(view);
  if (coordinator == nil) return nil;
  __weak id<UIViewControllerTransitionCoordinator> weakCoordinator = coordinator;
  [coordinator animateAlongsideTransition:nil
                               completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
    id<UIViewControllerTransitionCoordinator> ended = weakCoordinator;
    if (ended != nil) [SmoothClipEndedTransitions() addObject:ended];
    block();
  }];
  return coordinator;
}

@interface SmoothClipFlightLayerView : UIView
@end

@implementation SmoothClipFlightLayerView
// Never part of hit testing: touches go to the screens underneath.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
  return nil;
}
@end

@implementation SmoothClipFlightCoordinator {
  // tag -> targets, oldest first. Weak: a target that deallocates drops out.
  NSMutableDictionary<NSString *, NSPointerArray *> *_targets;
  // tag -> airborne hosts.
  NSMutableDictionary<NSString *, NSHashTable *> *_airborne;
}

+ (instancetype)shared {
  static SmoothClipFlightCoordinator *coordinator;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    coordinator = [SmoothClipFlightCoordinator new];
  });
  return coordinator;
}

- (instancetype)init {
  if (self = [super init]) {
    _targets = [NSMutableDictionary dictionary];
    _airborne = [NSMutableDictionary dictionary];
  }
  return self;
}

- (UIView *)flightLayerForWindow:(UIWindow *)window {
  UIView *layer = objc_getAssociatedObject(window, kSmoothClipFlightLayerKey);
  if (layer == nil || layer.superview != window) {
    layer = [[SmoothClipFlightLayerView alloc] initWithFrame:window.bounds];
    layer.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    layer.userInteractionEnabled = NO;
    layer.accessibilityElementsHidden = YES;
    layer.layer.zPosition = 1000;
    [window addSubview:layer];
    objc_setAssociatedObject(
        window, kSmoothClipFlightLayerKey, layer,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  } else if (window.subviews.lastObject != layer) {
    [window bringSubviewToFront:layer];
  }
  return layer;
}

#pragma mark - Targets

- (void)target:(SmoothClipFlightTargetView *)target
    didChangeTagFrom:(NSString *)oldTag {
  if (oldTag.length > 0) {
    NSPointerArray *list = _targets[oldTag];
    for (NSUInteger index = list.count; index > 0; index -= 1) {
      if ([list pointerAtIndex:index - 1] == (__bridge void *)target) {
        [list removePointerAtIndex:index - 1];
      }
    }
    // A target that deallocates with its tag still set reads as NULL here,
    // and `compact` only drops zeroed weak slots once the array has seen an
    // explicit NULL. Without this, such a tag keeps its list for good.
    [list addPointer:NULL];
    [list compact];
    if (list.count == 0) [_targets removeObjectForKey:oldTag];
    // A flight that waits on this target (not `ready`, or arriving) must not
    // wait for one that left its tag: nothing else would wake it.
    [self notifyHostsForTag:oldTag];
  }
  NSString *tag = target.flightTag;
  if (tag.length == 0) {
    target.flightCovered = NO;
    return;
  }
  NSPointerArray *list = _targets[tag];
  if (list == nil) {
    list = [NSPointerArray weakObjectsPointerArray];
    _targets[tag] = list;
  }
  [list addPointer:(__bridge void *)target];
  // A target that mounts while its flight is airborne (the route of a source
  // flight) is hidden in the same mount, so it never shows beside the flight.
  target.flightCovered = [self isTagAirborne:tag];
  [self notifyHostsForTag:tag];
}

- (void)targetStateDidChange:(SmoothClipFlightTargetView *)target {
  NSString *tag = target.flightTag;
  if (tag.length == 0) return;
  if ([self isTagAirborne:tag] && !target.flightCovered) {
    target.flightCovered = YES;
  }
  [self notifyHostsForTag:tag];
}

- (SmoothClipFlightTargetView *)attachedTargetForTag:(NSString *)tag {
  if (tag.length == 0) return nil;
  NSPointerArray *list = _targets[tag];
  for (NSUInteger index = list.count; index > 0; index -= 1) {
    SmoothClipFlightTargetView *target =
        (__bridge SmoothClipFlightTargetView *)[list pointerAtIndex:index - 1];
    // A recycled view re-registers under its new tag; check it still has this.
    if (target != nil && target.window != nil &&
        [target.flightTag isEqualToString:tag]) {
      return target;
    }
  }
  return nil;
}

- (SmoothClipFlightTargetView *)registeredTargetForTag:(NSString *)tag {
  if (tag.length == 0) return nil;
  NSPointerArray *list = _targets[tag];
  for (NSUInteger index = list.count; index > 0; index -= 1) {
    SmoothClipFlightTargetView *target =
        (__bridge SmoothClipFlightTargetView *)[list pointerAtIndex:index - 1];
    if (target != nil && [target.flightTag isEqualToString:tag]) return target;
  }
  return nil;
}

- (void)notifyHostsForTag:(NSString *)tag {
  NSHashTable *hosts = _airborne[tag];
  for (id<SmoothClipFlightHost> host in hosts.allObjects) {
    [host smoothClipFlightTargetsDidChange];
  }
}

#pragma mark - Airborne hosts

- (void)host:(id<SmoothClipFlightHost>)host didLiftWithTag:(NSString *)tag {
  if (tag.length == 0) return;
  NSHashTable *hosts = _airborne[tag];
  if (hosts == nil) {
    hosts = [NSHashTable weakObjectsHashTable];
    _airborne[tag] = hosts;
  }
  [hosts addObject:host];
  NSPointerArray *list = _targets[tag];
  for (NSUInteger index = 0; index < list.count; index += 1) {
    SmoothClipFlightTargetView *target =
        (__bridge SmoothClipFlightTargetView *)[list pointerAtIndex:index];
    if ([target.flightTag isEqualToString:tag]) target.flightCovered = YES;
  }
}

- (void)host:(id<SmoothClipFlightHost>)host didLandWithTag:(NSString *)tag {
  if (tag.length == 0) return;
  NSHashTable *hosts = _airborne[tag];
  [hosts removeObject:host];
  if (hosts.allObjects.count > 0) return;
  [_airborne removeObjectForKey:tag];
  NSPointerArray *list = _targets[tag];
  for (NSUInteger index = 0; index < list.count; index += 1) {
    SmoothClipFlightTargetView *target =
        (__bridge SmoothClipFlightTargetView *)[list pointerAtIndex:index];
    if ([target.flightTag isEqualToString:tag]) target.flightCovered = NO;
  }
}

- (BOOL)isTagAirborne:(NSString *)tag {
  return tag.length > 0 && _airborne[tag].allObjects.count > 0;
}

@end
