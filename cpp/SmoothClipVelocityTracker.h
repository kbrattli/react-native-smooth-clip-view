#pragma once

#include <array>
#include <cmath>

namespace smoothclip {

// The two most recent interactive samples used by `initialVelocity: 'inherit'`.
// Channels are the seven presentation scalars (x, y, width, height, radius,
// contentTranslateX, contentTranslateY) but the tracker is value-agnostic:
// iOS records normalized (host-clamped) geometry, Android raw DIP — the
// projection only needs both samples and the target in the same space.
// Shared by ios/SmoothClipView.mm and android/.../SmoothClipRegistry.cpp; a
// behavior change here changes both platforms.
struct VelocitySampleHistory {
  bool hasPrevious = false;
  bool hasLatest = false;
  std::array<double, 7> previous{};
  std::array<double, 7> latest{};
  double previousTimeS = 0;
  double latestTimeS = 0;
};

// Two records closer than this are one observation of the same frame (an
// ACTION_UP adoption or an animateTo `from` seed lands in the same input
// batch as the last drag write, ~1 ms apart). The window sits well above
// batch spacing and below the 8.33 ms 120 Hz frame, so legitimate
// consecutive-frame samples never coalesce.
inline constexpr double kSampleCoalesceWindowS = 0.004;
// A latest sample older than this no longer describes the finger; 'inherit'
// yields zero instead of replaying stale motion.
inline constexpr double kVelocityStalenessS = 0.1;

inline void recordVelocitySample(
    VelocitySampleHistory &history,
    const std::array<double, 7> &channels,
    double nowS) {
  if (history.hasLatest && channels == history.latest) {
    // Identical re-record (a `from` seed equal to the last interactive
    // write): keep the pair and its timestamps, so the last real motion
    // still ages out through the staleness guard instead of zeroing the
    // sample deltas.
    return;
  }
  if (history.hasLatest &&
      nowS - history.latestTimeS < kSampleCoalesceWindowS) {
    // Same-frame re-record: replace the latest sample in place instead of
    // rotating, so the surviving pair spans a real frame interval. Rotating
    // here would divide the extra sub-frame displacement by microseconds and
    // explode the inherited velocity.
    history.latest = channels;
    history.latestTimeS = nowS;
    return;
  }
  history.hasPrevious = history.hasLatest;
  history.previous = history.latest;
  history.previousTimeS = history.latestTimeS;
  history.hasLatest = true;
  history.latest = channels;
  history.latestTimeS = nowS;
}

// beginInteraction on both platforms records the frozen presentation as a
// plain sample: a grab mid-animation pairs the frozen value with the last
// real sample, so an instant refling inherits bounded recent motion instead
// of launching dead, and a grab at an unchanged value dedupes to a no-op
// whose staleness keeps aging. There is deliberately no reset primitive —
// the 100 ms staleness guard is the forgetting mechanism.

inline void clearVelocitySamples(VelocitySampleHistory &history) {
  history = VelocitySampleHistory{};
}

// Normalized velocity of the recorded motion projected onto the
// latest→target trajectory, in units of remaining-distance per second
// (1 covers the remaining distance in one second) — the CASpringAnimation
// initialVelocity convention. iOS passes the scalar unchanged per keypath;
// Android seeds each integrator channel with scalar·displacement.
inline double inheritedVelocity(
    const VelocitySampleHistory &history,
    const std::array<double, 7> &target,
    double nowS) {
  if (!history.hasPrevious || !history.hasLatest) return 0;
  const double elapsed = history.latestTimeS - history.previousTimeS;
  if (elapsed <= 0 || nowS - history.latestTimeS > kVelocityStalenessS) {
    return 0;
  }
  double numerator = 0;
  double denominator = 0;
  for (int index = 0; index < 7; index += 1) {
    const double sampleDelta = history.latest[index] - history.previous[index];
    const double destinationDelta = target[index] - history.latest[index];
    numerator += sampleDelta * destinationDelta;
    denominator += destinationDelta * destinationDelta;
  }
  if (denominator <= 1e-12) return 0;
  const double result = numerator / elapsed / denominator;
  return std::isfinite(result) ? result : 0;
}

} // namespace smoothclip
