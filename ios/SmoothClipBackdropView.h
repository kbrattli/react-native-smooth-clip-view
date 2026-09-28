#import <React/RCTViewComponentView.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * A view translated by its controller's backdrop channel. The registry writes
 * the channel to an inner content layer on every setFrame and adds a
 * translation animation to every native run on the clip's shared Core
 * Animation epoch, so the content is sampled by the same clock as the
 * aperture and never lands a frame late. The view's own layer keeps React
 * Native's transform.
 */
@interface SmoothClipBackdropView : RCTViewComponentView
@end

NS_ASSUME_NONNULL_END
