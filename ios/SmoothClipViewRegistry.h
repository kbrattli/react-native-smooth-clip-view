#import <Foundation/Foundation.h>

#include <cstddef>
#include "SmoothClipRegistry.h"

@class SmoothClipView;

namespace smoothclip {

void registerView(
    uint64_t driverId,
    SmoothClipView *view,
    Presentation initialPresentation);
void unregisterView(uint64_t driverId, SmoothClipView *view);
// Re-runs the mid-animation join for a registered view whose animation
// install was deferred because it had no layout yet. Returns false when the
// driver or its active animation no longer exists.
bool joinActiveAnimation(uint64_t driverId, SmoothClipView *view);
// Called when a registered view first becomes able to produce a visible
// frame (has layout AND is attached to a window). Starts a latched animation
// — rebasing its clock so no progress is burned while the view was
// detached — or completes a deferred install for an already-running one.
// A CA animation committed while the host's layer tree is detached (e.g. a
// transparentModal subtree before its view controller is presented) does not
// survive the attach commit; installs must therefore wait for this signal.
void viewBecameDisplayable(uint64_t driverId, SmoothClipView *view);
void viewAnimationDidStop(
    uint64_t driverId,
    int32_t animationId,
    SmoothClipView *view,
    bool finished);
size_t registeredViewCount(uint64_t driverId);
bool hasActiveAnimation(uint64_t driverId);

} // namespace smoothclip
