#import <XCTest/XCTest.h>

#include "SmoothClipVelocityTracker.h"

#include <array>
#include <cmath>

// Deterministic, injected-timestamp tests for the shared velocity tracker
// (cpp/SmoothClipVelocityTracker.h) — the exact code SmoothClipView.mm
// (per view) and the Android registry (per driver) execute for
// `initialVelocity: 'inherit'`. Android has no C++ test harness, so the
// shared behavior is pinned here.

static std::array<double, 11> Channels(double x, double y) {
  return {x, y, 40, 40, 8, 8, 8, 8, 0, 0, 1};
}

@interface SmoothClipVelocityTrackerTests : XCTestCase
@end

@implementation SmoothClipVelocityTrackerTests

- (void)testIdenticalSeedIsDeduplicatedAndKeepsHonestVelocity {
  smoothclip::VelocitySampleHistory history;
  smoothclip::recordVelocitySample(history, Channels(0, 0), 0.0);
  smoothclip::recordVelocitySample(history, Channels(0, 8), 0.016);
  // A `from` seed identical to the last drag write, 0.3 ms later: dropped
  // without touching the timestamps, so the pair keeps the last real motion
  // instead of zeroing its deltas (the pre-fix Android dead-spring launch).
  smoothclip::recordVelocitySample(history, Channels(0, 8), 0.0163);
  XCTAssertEqual(history.latestTimeS, 0.016);

  const double velocity =
      smoothclip::inheritedVelocity(history, Channels(0, 100), 0.0165);
  // (8 DIP / 16 ms) projected onto the remaining 92 DIP.
  XCTAssertEqualWithAccuracy(velocity, 8.0 / 0.016 / 92.0, 1e-9);
  XCTAssertGreaterThan(velocity, 0.0);
}

- (void)testDistinctSeedInsideCoalesceWindowMergesIntoOneObservation {
  smoothclip::VelocitySampleHistory history;
  smoothclip::recordVelocitySample(history, Channels(0, 0), 0.0);
  smoothclip::recordVelocitySample(history, Channels(0, 8), 0.016);
  // A distinct release sample 0.3 ms after the last drag write (the
  // ACTION_UP-is-fresher case): replaces the latest in place, so the pair
  // spans the real frame interval instead of 0.3 ms.
  smoothclip::recordVelocitySample(history, Channels(0, 9), 0.0163);
  XCTAssertTrue(history.hasPrevious);
  XCTAssertEqual(history.previousTimeS, 0.0);
  XCTAssertEqual(history.latestTimeS, 0.0163);

  const double velocity =
      smoothclip::inheritedVelocity(history, Channels(0, 100), 0.0165);
  XCTAssertEqualWithAccuracy(velocity, 9.0 / 0.0163 / 91.0, 1e-9);
  // Pre-fix, rotation would have measured 1 DIP over 0.3 ms:
  // 1 / 0.0003 / 91 ≈ 36.6 — a spring seeded to cover the remaining
  // distance ~37× per second. The coalesced value stays honest.
  XCTAssertLessThan(velocity, 8.0);
}

- (void)testConsecutiveSamplesAtHundredTwentyHertzStillRotate {
  smoothclip::VelocitySampleHistory history;
  smoothclip::recordVelocitySample(history, Channels(0, 0), 0.0);
  smoothclip::recordVelocitySample(history, Channels(0, 4), 0.0084);
  // 8.4 ms spacing (120 Hz + jitter) is above the 4 ms coalesce window:
  // legitimate per-frame cadence must rotate, never merge.
  smoothclip::recordVelocitySample(history, Channels(0, 8), 0.0168);
  XCTAssertTrue(history.hasPrevious);
  XCTAssertEqual(history.previousTimeS, 0.0084);
  XCTAssertEqual(history.latestTimeS, 0.0168);

  const double velocity =
      smoothclip::inheritedVelocity(history, Channels(0, 100), 0.017);
  XCTAssertEqualWithAccuracy(velocity, 4.0 / 0.0084 / 92.0, 1e-9);
}

- (void)testStaleLatestSampleInheritsZeroVelocity {
  smoothclip::VelocitySampleHistory history;
  smoothclip::recordVelocitySample(history, Channels(0, 0), 0.0);
  smoothclip::recordVelocitySample(history, Channels(0, 8), 0.016);
  // 0.2 − 0.016 > kVelocityStalenessS: the motion no longer describes the
  // finger.
  XCTAssertEqual(
      smoothclip::inheritedVelocity(history, Channels(0, 100), 0.2), 0.0);
}

- (void)testStalenessCreditIsUndiminishedInsideTheGraceWindow {
  // An ordinary fling issues animateTo in the same input batch as, or one
  // frame after, the last drag write. That handoff must not be scaled at all.
  XCTAssertEqual(smoothclip::velocityStalenessCredit(0), 1.0);
  XCTAssertEqual(smoothclip::velocityStalenessCredit(1.0 / 120.0), 1.0);
  XCTAssertEqual(
      smoothclip::velocityStalenessCredit(smoothclip::kVelocityFullCreditS),
      1.0);
}

- (void)testStalenessCreditDecaysToZeroWithoutAStep {
  // The pre-0.2.7 cliff: a release after a 99 ms still-hold inherited the
  // full drag velocity, 101 ms inherited none. The two ends now meet.
  XCTAssertEqualWithAccuracy(
      smoothclip::velocityStalenessCredit(0.05), 0.6, 1e-12);
  XCTAssertEqualWithAccuracy(
      smoothclip::velocityStalenessCredit(0.099), 0.012, 1e-12);
  XCTAssertEqual(
      smoothclip::velocityStalenessCredit(smoothclip::kVelocityStalenessS),
      0.0);
  XCTAssertEqual(smoothclip::velocityStalenessCredit(0.5), 0.0);

  // Monotone and continuous across the whole range: sweeping the hold in 1 ms
  // steps may never increase the credit, and may never move it by more than
  // one step's worth — which is what "no step the hand can feel" means.
  const double maxStep =
      0.001 / (smoothclip::kVelocityStalenessS -
               smoothclip::kVelocityFullCreditS);
  double previous = 1.0;
  for (int step = 0; step <= 200; step += 1) {
    const double credit = smoothclip::velocityStalenessCredit(step * 0.001);
    XCTAssertLessThanOrEqual(credit, previous + 1e-12);
    XCTAssertLessThanOrEqual(std::fabs(credit - previous), maxStep + 1e-12);
    previous = credit;
  }
  XCTAssertEqual(previous, 0.0);
}

- (void)testHoldBeforeReleaseScalesTheInheritedVelocity {
  smoothclip::VelocitySampleHistory history;
  smoothclip::recordVelocitySample(history, Channels(0, 0), 0.0);
  smoothclip::recordVelocitySample(history, Channels(0, 8), 0.016);
  const double undecayed = 8.0 / 0.016 / 92.0;

  // Released in the same frame as the last drag write: untouched.
  XCTAssertEqualWithAccuracy(
      smoothclip::inheritedVelocity(history, Channels(0, 100), 0.0165),
      undecayed,
      1e-9);
  // Held still for 50 ms first: 60% of the drag velocity, not all of it.
  XCTAssertEqualWithAccuracy(
      smoothclip::inheritedVelocity(history, Channels(0, 100), 0.066),
      undecayed * 0.6,
      1e-9);
  // 99 ms: nearly dead, but arrived at smoothly rather than off a cliff.
  XCTAssertEqualWithAccuracy(
      smoothclip::inheritedVelocity(history, Channels(0, 100), 0.115),
      undecayed * 0.012,
      1e-9);
  XCTAssertEqual(
      smoothclip::inheritedVelocity(history, Channels(0, 100), 0.116), 0.0);
}

- (void)testSingleObservationInheritsZeroVelocity {
  smoothclip::VelocitySampleHistory history;
  // A fresh history (view init / prepareForRecycle) holds at most one
  // observation after the first write.
  smoothclip::recordVelocitySample(history, Channels(0, 0), 0.0);
  // An instant release seed lands inside the coalesce window and merges into
  // the same single observation — still no pair, still zero velocity (the
  // pre-fix rotation formed a sub-ms pair here and exploded).
  smoothclip::recordVelocitySample(history, Channels(0, 3), 0.002);
  XCTAssertFalse(history.hasPrevious);
  XCTAssertEqual(
      smoothclip::inheritedVelocity(history, Channels(0, 100), 0.003), 0.0);
}

// A real interactive write after a pause remains a normal sample: it pairs
// with the prior write and still uses the true elapsed time.
- (void)testRecentInteractiveWriteAfterPausePairsWithThePriorSample {
  smoothclip::VelocitySampleHistory history;
  smoothclip::recordVelocitySample(history, Channels(0, 0), 0.0);
  smoothclip::recordVelocitySample(history, Channels(0, 8), 0.016);
  // The user pauses for 60 ms, then drags to y=30.
  smoothclip::recordVelocitySample(history, Channels(0, 30), 0.076);
  XCTAssertTrue(history.hasPrevious);
  XCTAssertEqual(history.previousTimeS, 0.016);

  // Instant release: 22 DIP since the last sample over 60 ms projected
  // onto the remaining 70 DIP — bounded, not zero, no explosion.
  const double velocity =
      smoothclip::inheritedVelocity(history, Channels(0, 100), 0.077);
  XCTAssertEqualWithAccuracy(velocity, 22.0 / 0.06 / 70.0, 1e-9);
}

- (void)testProjectionMatchesReferenceVectorsAndGuardsZeroDenominator {
  smoothclip::VelocitySampleHistory history;
  const std::array<double, 11> previous = {
      0, 0, 40, 40, 8, 8, 8, 8, 0, 0, 1};
  const std::array<double, 11> latest = {
      2, 5, 42, 39, 8, 8, 8, 8, -1, 3, 1};
  const std::array<double, 11> target = {
      10, 80, 100, 100, 12, 12, 12, 12, -20, -30, 1};
  smoothclip::recordVelocitySample(history, previous, 0.0);
  smoothclip::recordVelocitySample(history, latest, 0.02);

  // Hand-computed: Σ(sampleΔ·destΔ) = 366, Σ(destΔ²) = 14240 — pins the
  // projection math against drift during any future extraction/refactor.
  const double velocity =
      smoothclip::inheritedVelocity(history, target, 0.021);
  XCTAssertEqualWithAccuracy(velocity, 366.0 / 0.02 / 14240.0, 1e-9);

  // latest == target ⇒ zero remaining distance ⇒ guarded to 0, not NaN.
  XCTAssertEqual(smoothclip::inheritedVelocity(history, latest, 0.021), 0.0);
}

@end
