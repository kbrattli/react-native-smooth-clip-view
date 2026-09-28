#import <Foundation/Foundation.h>

#include <cstddef>
#include "SmoothClipRegistry.h"
#include "SmoothClipRegistrySnapshot.h"

@class SmoothClipView;
@class SmoothClipBackdropView;

namespace smoothclip {

void registerView(
    uint64_t driverId,
    SmoothClipView *view,
    Presentation initialPresentation);
void unregisterView(uint64_t driverId, SmoothClipView *view);
// Binds a backdrop view to a driver: the registry writes the presentation's
// backdrop channel to it on every setFrame and adds a translation animation
// to every run, on the clip's shared Core Animation epoch. Any number may
// bind; one binding mid-run adopts the driver's current value.
void registerBackdropView(uint64_t driverId, SmoothClipBackdropView *view);
void unregisterBackdropView(uint64_t driverId, SmoothClipBackdropView *view);
// Called when a registered view first becomes able to produce a visible
// frame (has layout AND is attached to a window). Starts a pre-ready animation
// with its full duration so no progress is burned while the view was detached.
// A CA animation committed while the host's layer tree is detached (e.g. a
// transparentModal subtree before its view controller is presented) does not
// survive the attach commit; installs must therefore wait for this signal.
void viewDisplayabilityChanged(uint64_t driverId, SmoothClipView *view);
void applicationWillResignActive();
void applicationDidBecomeActive();
bool applicationIsActive();
void viewAnimationDidStop(
    uint64_t driverId,
    int32_t animationId,
    SmoothClipView *view,
    bool finished);
size_t registeredViewCount(uint64_t driverId);
bool hasActiveAnimation(uint64_t driverId);

} // namespace smoothclip

// Baked shadow tile cache (SmoothClipView.mm), for tests: tiles baked so far
// in this process, tiles waiting to bake off the frame, and a synchronous
// drain of that queue.
NSUInteger SmoothClipShadowTileBakeCountForTesting(void);
NSUInteger SmoothClipPendingShadowTileCountForTesting(void);
void SmoothClipBakePendingShadowTilesForTesting(void);
