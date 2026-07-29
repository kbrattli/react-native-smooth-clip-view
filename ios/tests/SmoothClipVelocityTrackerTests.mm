#import <XCTest/XCTest.h>

#include "SmoothClipVelocityTracker.h"

#include <array>
#include <cmath>

// Deterministic, injected-timestamp tests for the shared velocity tracker
// (cpp/SmoothClipVelocityTracker.h) — the exact code SmoothClipView.mm
// (per view) and the Android registry (per driver) execute for
// `initialVelocity: 'inherit'`. Android has no C++ test harness, so the
// shared behavior is pinned here.

static std::array<double, 7> Channels(double x, double y) {
  return {x, y, 40, 40, 8, 0, 0};
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

- (void)testSingleObservationInheritsZeroVelocity {
  smoothclip::VelocitySampleHistory history;
  // beginInteraction semantics: history restarts from one fresh sample.
  smoothclip::resetVelocitySamples(history, Channels(0, 0), 0.0);
  // An instant release seed lands inside the coalesce window and merges into
  // the same single observation — still no pair, still zero velocity (the
  // pre-fix rotation formed a sub-ms pair here and exploded).
  smoothclip::recordVelocitySample(history, Channels(0, 3), 0.002);
  XCTAssertFalse(history.hasPrevious);
  XCTAssertEqual(
      smoothclip::inheritedVelocity(history, Channels(0, 100), 0.003), 0.0);
}

- (void)testProjectionMatchesReferenceVectorsAndGuardsZeroDenominator {
  smoothclip::VelocitySampleHistory history;
  const std::array<double, 7> previous = {0, 0, 40, 40, 8, 0, 0};
  const std::array<double, 7> latest = {2, 5, 42, 39, 8, -1, 3};
  const std::array<double, 7> target = {10, 80, 100, 100, 12, -20, -30};
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
