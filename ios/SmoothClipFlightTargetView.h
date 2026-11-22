#import <React/RCTViewComponentView.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * The other endpoint of a flight (`<SmoothClipFlightTarget tag>`). Fabric
 * mounts its children into an inner container that only the flight machinery
 * hides, so the view's React styles (opacity, display) are never written
 * behind Fabric's back.
 */
@interface SmoothClipFlightTargetView : RCTViewComponentView

/** The `flightTag` prop; empty when unset. */
@property (nonatomic, readonly, copy) NSString *flightTag;
/** The `ready` prop: a landing flight waits until it is true. */
@property (nonatomic, readonly) BOOL flightReady;
/** Set by the coordinator while a flight with this tag is airborne. */
@property (nonatomic) BOOL flightCovered;
/** True while this view's screen runs a UIKit transition. */
@property (nonatomic, readonly) BOOL flightInTransition;

@end

NS_ASSUME_NONNULL_END
