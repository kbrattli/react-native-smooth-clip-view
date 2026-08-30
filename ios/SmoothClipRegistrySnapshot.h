#pragma once

#include <cstdint>

#include "SmoothClipRegistry.h"

namespace smoothclip {

// Returns the canonical presentation currently visible for a driver without
// changing ownership or interrupting an active animation.
Presentation snapshotCurrent(uint64_t driverId);

} // namespace smoothclip
