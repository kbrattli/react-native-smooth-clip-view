#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class SmoothClipFlightTargetView;

/** A SmoothClipView with `flight`, as the coordinator sees it. */
@protocol SmoothClipFlightHost <NSObject>
/** A target with this host's tag registered, attached, or changed `ready`. */
- (void)smoothClipFlightTargetsDidChange;
@end

/**
 * Process-wide, main-thread-only bookkeeping for flights: the per-window
 * flight layer, the tag -> target registry, and which tags are airborne.
 * Hosts own their flights; the coordinator only connects them to targets.
 */
@interface SmoothClipFlightCoordinator : NSObject

+ (instancetype)shared;

/**
 * The window's flight layer: created on first use, above every screen and
 * modal container (zPosition), never hit-testable, and hidden from
 * accessibility. Brought to the front of the window's subviews on each call.
 */
- (UIView *)flightLayerForWindow:(UIWindow *)window;

/** Registers `target` under its current tag (and drops it from `oldTag`). */
- (void)target:(SmoothClipFlightTargetView *)target
    didChangeTagFrom:(nullable NSString *)oldTag;
/** The target's window, `ready` or transition state changed. */
- (void)targetStateDidChange:(SmoothClipFlightTargetView *)target;
/** The most recently registered target with `tag` that is in a window. */
- (nullable SmoothClipFlightTargetView *)attachedTargetForTag:(NSString *)tag;
/**
 * The most recently registered target with `tag`, attached or not: a pushed
 * route's target mounts one message before react-native-screens attaches it.
 */
- (nullable SmoothClipFlightTargetView *)registeredTargetForTag:(NSString *)tag;

/** `host` is airborne under `tag`: targets with it hide, now and on mount. */
- (void)host:(id<SmoothClipFlightHost>)host didLiftWithTag:(NSString *)tag;
/** `host` landed; its tag stops covering targets unless another host flies it. */
- (void)host:(id<SmoothClipFlightHost>)host didLandWithTag:(NSString *)tag;
- (BOOL)isTagAirborne:(NSString *)tag;

@end

/** The view controller whose view contains `view` (responder chain). */
UIViewController *_Nullable SmoothClipOwningViewController(UIView *view);
/**
 * The UIKit transition `view`'s view controller (or a parent) runs, if any.
 * A transition whose completion SmoothClipObserveTransitionEnd already saw
 * no longer counts, even while UIKit still reports it.
 */
id<UIViewControllerTransitionCoordinator> _Nullable
SmoothClipViewTransitionCoordinator(UIView *view);
/** True while `view`'s view controller runs a UIKit transition. */
BOOL SmoothClipViewIsInTransition(UIView *view);
/**
 * Runs `block` once the transition `view` is in completes (or cancels).
 * Returns the observed coordinator, or nil when `view` is not in one.
 */
id<UIViewControllerTransitionCoordinator> _Nullable
SmoothClipObserveTransitionEnd(UIView *view, dispatch_block_t block);

NS_ASSUME_NONNULL_END
