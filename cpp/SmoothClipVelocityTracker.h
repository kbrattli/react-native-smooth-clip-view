#pragma once

#include <array>
#include <cmath>

namespace smoothclip {

// The two most recent interactive samples used by `initialVelocity: 'inherit'`.
// Channels are the eleven continuous V2 presentation scalars. Scale is stored
// so histories remain coherent but excluded from velocity projection; each of
// the four radius channels contributes one quarter of the legacy radius weight.
// iOS records normalized (host-clamped) geometry, Android raw DIP — the
// projection only needs both samples and the target in the same space.
// Shared by ios/SmoothClipView.mm and android/.../SmoothClipRegistry.cpp; a
// behavior change here changes both platforms.
struct VelocitySampleHistory {
  bool hasPrevious = false;
  bool hasLatest = false;
  std::array<double, 11> previous{};
  std::array<double, 11> latest{};
  double previousTimeS = 0;
  double latestTimeS = 0;
};

// Two records closer than this are one observation of the same frame (an
// ACTION_UP adoption or an animateTo `from` seed lands in the same input
// batch as the last drag write, ~1 ms apart). The window sits well above
// batch spacing and below the 8.33 ms 120 Hz frame, so legitimate
// consecutive-frame samples never coalesce.
inline constexpr double kSampleCoalesceWindowS = 0.004;
// A latest sample this old no longer describes the finger at all; 'inherit'
// yields zero rather than replaying stale motion. It is the far end of the
// decay below, not a cliff.
inline constexpr double kVelocityStalenessS = 0.1;
// Below this age the sample is still "now": an ordinary fling calls animateTo
// in the same input batch as, or one frame after, the last drag write, and
// must inherit its motion undiminished. Decaying from zero age instead would
// shave ~17% off every normal handoff at 60 Hz — a regression in the case that
// matters most, in exchange for fixing the case that barely happens.
inline constexpr double kVelocityFullCreditS = 1.0 / 60.0;

inline void recordVelocitySample(
    VelocitySampleHistory &history,
    const std::array<double, 11> &channels,
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

// Only explicit interactive writes route through this recorder. Native
// freeze/join/resume/static-finalization paths deliberately do not, so an
// animation cannot manufacture a later inherited velocity. During ordinary
// interaction, the staleness decay below is the forgetting mechanism and it
// forgets gradually rather than all at once.

inline void clearVelocitySamples(VelocitySampleHistory &history) {
  history = VelocitySampleHistory{};
}

// Age of the newest sample expressed as a credit multiplier: full inside the
// grace window, decaying linearly to zero at the staleness bound. The old
// binary cutoff meant a release after a 99 ms still-hold launched at the full
// drag velocity while 101 ms launched dead — a step the hand can feel, and one
// RNGH's own windowed event.velocity* does not have. Continuous and monotone
// in holdS, so no hold duration produces a discontinuity in launch speed.
inline double velocityStalenessCredit(double holdS) {
  if (holdS <= kVelocityFullCreditS) return 1;
  if (holdS >= kVelocityStalenessS) return 0;
  return (kVelocityStalenessS - holdS) /
      (kVelocityStalenessS - kVelocityFullCreditS);
}

// Normalized velocity of the recorded motion projected onto the
// latest→target trajectory, in units of remaining-distance per second
// (1 covers the remaining distance in one second) — the CASpringAnimation
// initialVelocity convention. iOS passes the scalar unchanged per keypath;
// Android seeds each integrator channel with scalar·displacement.
inline double inheritedVelocity(
    const VelocitySampleHistory &history,
    const std::array<double, 11> &target,
    double nowS) {
  if (!history.hasPrevious || !history.hasLatest) return 0;
  const double elapsed = history.latestTimeS - history.previousTimeS;
  const double credit = velocityStalenessCredit(nowS - history.latestTimeS);
  if (elapsed <= 0 || credit <= 0) {
    return 0;
  }
  double numerator = 0;
  double denominator = 0;
  for (int index = 0; index < 11; index += 1) {
    const double weight = index >= 4 && index <= 7
        ? 0.25
        : (index == 10 ? 0.0 : 1.0);
    const double sampleDelta = history.latest[index] - history.previous[index];
    const double destinationDelta = target[index] - history.latest[index];
    numerator += weight * sampleDelta * destinationDelta;
    denominator += weight * destinationDelta * destinationDelta;
  }
  if (denominator <= 1e-12) return 0;
  const double result = numerator / elapsed / denominator * credit;
  return std::isfinite(result) ? result : 0;
}

} // namespace smoothclip
