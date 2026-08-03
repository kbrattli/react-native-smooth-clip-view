#pragma once

#include <atomic>
#include <cstdint>
#include <limits>

namespace smoothclip {

// Completion delivery is asynchronous with respect to registry teardown. A
// per-driver counter is therefore not an identity: destroying the last host
// erases that counter, and an effect replay can recreate the same driver and
// allocate the same id before the old completion reaches JS. Keep ids unique
// for the practical lifetime of the process instead. The supported call paths
// are main-thread confined, but the atomic keeps this header safe if a future
// rejection path allocates before reaching that guard.
inline int32_t allocateAnimationId() {
  static std::atomic<int32_t> next{0};
  int32_t observed = next.load(std::memory_order_relaxed);
  while (true) {
    const int32_t desired =
        observed == std::numeric_limits<int32_t>::max() ? 1 : observed + 1;
    if (next.compare_exchange_weak(
            observed,
            desired,
            std::memory_order_relaxed,
            std::memory_order_relaxed)) {
      return desired;
    }
  }
}

} // namespace smoothclip
