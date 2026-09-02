#import <XCTest/XCTest.h>

#include "SmoothClipAnimationCurve.h"

#include <cmath>

// Deterministic tests for the shared animation curve (cpp/SmoothClipAnimationCurve.h)
// — the exact code the Android integrator executes every frame for the
// frame-clock anchor, timing, and spring evaluation. The Android
// registry translation unit is bound to fbjni and cannot be linked into a test
// binary, so, as with the shared velocity tracker, the behavior is pinned here.
//
// iOS does not evaluate this header at runtime (CoreAnimation drives its own
// animations); it only hosts these tests.

using smoothclip::Presentation;

namespace {

Presentation presentationWithScale(double scale) {
  return Presentation{{0, 0, 10, 10, 0}, 0, 0, scale};
}

} // namespace

@interface SmoothClipAnimationCurveTests : XCTestCase
@end

@implementation SmoothClipAnimationCurveTests

#pragma mark - Frame clock anchor

- (void)testAnchorKeepsTheWallStampWhenTheCallPrecedesTheFrame {
  // The dominant path: ACTION_UP is unbatched, so a gesture onEnd runs outside
  // doFrame and the dispatching frame is later than the call. Keeping the wall
  // stamp is what makes the first fraction already positive (no duplicated
  // start frame) and what matches Reanimated, which takes the wall clock too.
  const double call = 1000.0;
  const double frame = 1000.008;
  XCTAssertEqual(smoothclip::anchorStartTime(call, frame), call);

  const double fraction = smoothclip::timingFraction(frame, call, 0.35);
  XCTAssertGreaterThan(fraction, 0.0);
}

- (void)testAnchorAdoptsTheFrameStampWhenTheCallHappensInsideThatFrame {
  // Started from a callback in the frame that dispatches us: Reanimated's
  // __frameTimestamp is that same frame stamp, so adopting it keeps both
  // engines on one phase instead of letting the fraction clamp to zero.
  const double frame = 1000.0;
  const double call = 1000.004;
  XCTAssertEqual(smoothclip::anchorStartTime(call, frame), frame);
}

- (void)testAnchoredStartCanNeverLeadTheFrameClock {
  // Why the run-ahead guard could be deleted: the anchored start is never
  // later than the frame stamp, so frame-axis elapsed can never exceed it.
  const double frames[] = {0.0, 1.0, 1000.0, 1e6};
  const double calls[] = {-1.0, 0.5, 1000.5, 1e6 + 5};
  for (double frame : frames) {
    for (double call : calls) {
      XCTAssertLessThanOrEqual(smoothclip::anchorStartTime(call, frame), frame);
    }
  }
}

#pragma mark - JS-captured start stamp

- (void)testStartStampHintIsAdoptedAndArrivesPreAnchored {
  // The stamp is Reanimated's own t0, read in the worklet that issued the
  // animateTo — microseconds before the native wall read. It must be adopted
  // verbatim and must NOT be re-anchored by min() on the first advance.
  const smoothclip::StartStamp stamp =
      smoothclip::resolveStartStamp(999.996, 1000.0);
  XCTAssertEqual(stamp.startedAtS, 999.996);
  XCTAssertTrue(stamp.frameClockAnchored);
}

- (void)testStartStampInputPhaseWallStampSurvivesAnEarlierFrame {
  // The branch min() got wrong: a CALLBACK_INPUT start at wall T+4ms whose
  // dispatching frame stamp is T. Reanimated keeps the wall stamp there
  // (__frameTimestamp is cleared outside its rAF flush), so the hint must
  // survive; the same-frame advance then clamps to fraction 0 — the start is
  // drawn once, exactly what Reanimated renders on that frame — and from the
  // next frame both engines share one t0.
  const double frame = 1000.0;
  const double callWall = 1000.004;
  const smoothclip::StartStamp stamp =
      smoothclip::resolveStartStamp(callWall, callWall);
  XCTAssertEqual(stamp.startedAtS, callWall);
  XCTAssertTrue(stamp.frameClockAnchored);
  XCTAssertEqual(smoothclip::timingFraction(frame, stamp.startedAtS, 0.35), 0.0);
}

- (void)testStartStampFallsBackToTheWallClockWhenAbsent {
  // NaN is the deliberate "no stamp" sentinel (tests, stamp-less callers,
  // iOS ignoring the field): behavior reduces to nowSeconds() + min().
  const smoothclip::StartStamp stamp =
      smoothclip::resolveStartStamp(NAN, 1000.0);
  XCTAssertEqual(stamp.startedAtS, 1000.0);
  XCTAssertFalse(stamp.frameClockAnchored);
}

- (void)testStartStampRejectsAForeignEpoch {
  // A stamp a second away from the native clock is a broken epoch, not a
  // dispatch delay. Trusting it would complete every animation on its first
  // frame (stamp far in the past) or freeze it (far in the future); falling
  // back to the native clock is strictly safer.
  const smoothclip::StartStamp past =
      smoothclip::resolveStartStamp(998.5, 1000.0);
  XCTAssertEqual(past.startedAtS, 1000.0);
  XCTAssertFalse(past.frameClockAnchored);

  const smoothclip::StartStamp future =
      smoothclip::resolveStartStamp(1001.5, 1000.0);
  XCTAssertEqual(future.startedAtS, 1000.0);
  XCTAssertFalse(future.frameClockAnchored);
}

#pragma mark - Timing fraction

- (void)testTimingFractionClampsAndCompletesDegenerateDurations {
  XCTAssertEqual(smoothclip::timingFraction(5.0, 1.0, 0.0), 1.0);
  XCTAssertEqual(smoothclip::timingFraction(5.0, 1.0, -1.0), 1.0);
  XCTAssertEqual(smoothclip::timingFraction(0.5, 1.0, 2.0), 0.0);
  XCTAssertEqual(smoothclip::timingFraction(9.0, 1.0, 2.0), 1.0);
  XCTAssertEqualWithAccuracy(
      smoothclip::timingFraction(2.0, 1.0, 2.0), 0.5, 1e-12);
}

#pragma mark - Shared scalar spring

- (void)testDefaultSpringMatchesRepresentativeReanimatedSteps {
  const smoothclip::SpringAnimation spring{4, 900, 120, 0, false, 2, 6e-9};
  smoothclip::ScalarSpringState state{0, 0};
  state = smoothclip::advanceScalarSpring(state, spring, 0.016);
  XCTAssertEqualWithAccuracy(state.position, 0.0245814523, 1e-9);
  XCTAssertEqualWithAccuracy(state.velocity, 2.8318602998, 1e-9);
  state = smoothclip::advanceScalarSpring(state, spring, 0.016);
  XCTAssertEqualWithAccuracy(state.position, 0.0842005801, 1e-9);
  XCTAssertEqualWithAccuracy(state.velocity, 4.4552404210, 1e-9);
}

- (void)testSpringClampsLongFramesAndUsesCriticalBranchAboveOne {
  const smoothclip::SpringAnimation spring{1, 100, 30, 2, false, 2, 6e-9};
  const smoothclip::ScalarSpringState state{0, 2};
  const smoothclip::ScalarSpringState clamped =
      smoothclip::advanceScalarSpring(state, spring, 0.5);
  const smoothclip::ScalarSpringState sixtyFourMs =
      smoothclip::advanceScalarSpring(state, spring, 0.064);
  XCTAssertEqualWithAccuracy(clamped.position, sixtyFourMs.position, 1e-12);
  XCTAssertEqualWithAccuracy(clamped.velocity, sixtyFourMs.velocity, 1e-12);
  XCTAssertTrue(std::isfinite(clamped.position));
  XCTAssertTrue(std::isfinite(clamped.velocity));
}

- (void)testRelativeEnergyIncludesExplicitInitialVelocity {
  const smoothclip::SpringAnimation spring{4, 900, 120, 5, false, 2, 6e-9};
  XCTAssertEqualWithAccuracy(
      smoothclip::relativeSpringEnergy({0, 5}, spring), 1, 1e-12);
  XCTAssertLessThan(
      smoothclip::relativeSpringEnergy({0.99999, 0.0001}, spring),
      6e-9);
}

- (void)testPositiveScaleCheckAcceptsSafeUnderdampedOvershoot {
  const smoothclip::SpringAnimation spring{1, 100, 10, 0, false, 2};
  XCTAssertTrue(smoothclip::springScaleStaysPositive(
      presentationWithScale(1), presentationWithScale(0.2), spring, 0));
}

- (void)testPositiveScaleCheckRejectsAnActualZeroCrossing {
  const smoothclip::SpringAnimation spring{1, 100, 1, 0, false, 2};
  XCTAssertFalse(smoothclip::springScaleStaysPositive(
      presentationWithScale(1), presentationWithScale(0.2), spring, 0));
}

- (void)testAutonomousGeometryIsLimitedToUniformCircularCorners {
  Presentation uniform{{0, 0, 100, 100, 12}, 0, 0, 1};
  uniform.clip.topLeftRadius = 12;
  uniform.clip.topRightRadius = 12;
  uniform.clip.bottomRightRadius = 12;
  uniform.clip.bottomLeftRadius = 12;
  XCTAssertTrue(smoothclip::isAutonomousUniformCircular(uniform));

  Presentation unequal = uniform;
  unequal.clip.topLeftRadius = 24;
  XCTAssertFalse(smoothclip::isAutonomousUniformCircular(unequal));

  Presentation continuous = uniform;
  continuous.clip.curve = smoothclip::ClipCurve::Continuous;
  XCTAssertFalse(smoothclip::isAutonomousUniformCircular(continuous));
}

#pragma mark - Shadow endpoint normalization

- (void)testVisibleToAbsentShadowIsAPureAlphaFade {
  Presentation from{{0, 0, 200, 200, 24}, 0, 0, 1};
  from.shadow = {true, 0.1, 0.2, 0.3, 0.4, 5, -2, 48, 7};
  Presentation to{{40, 50, 100, 80, 16}, 0, 0, 1};
  to.shadow = {false, 1, 1, 1, 1, 0, 0, 0, 0};

  const Presentation halfway = smoothclip::interpolate(from, to, 0.5);
  XCTAssertTrue(halfway.shadow.enabled);
  XCTAssertEqualWithAccuracy(halfway.shadow.red, 0.1, 1e-12);
  XCTAssertEqualWithAccuracy(halfway.shadow.green, 0.2, 1e-12);
  XCTAssertEqualWithAccuracy(halfway.shadow.blue, 0.3, 1e-12);
  XCTAssertEqualWithAccuracy(halfway.shadow.alpha, 0.2, 1e-12);
  XCTAssertEqualWithAccuracy(halfway.shadow.offsetX, 5, 1e-12);
  XCTAssertEqualWithAccuracy(halfway.shadow.offsetY, -2, 1e-12);
  XCTAssertEqualWithAccuracy(halfway.shadow.blurRadius, 48, 1e-12);
  XCTAssertEqualWithAccuracy(halfway.shadow.spreadDistance, 7, 1e-12);

  const Presentation terminal = smoothclip::interpolate(from, to, 1);
  XCTAssertFalse(terminal.shadow.enabled);
  XCTAssertEqualWithAccuracy(terminal.shadow.alpha, 0, 1e-12);
}

- (void)testAbsentToVisibleShadowUsesTheVisibleEndpointStyle {
  Presentation from{{40, 50, 100, 80, 16}, 0, 0, 1};
  Presentation to{{0, 0, 200, 200, 24}, 0, 0, 1};
  to.shadow = {true, 0.2, 0.3, 0.4, 0.6, 3, 4, 32, 5};

  const Presentation halfway = smoothclip::interpolate(from, to, 0.5);
  XCTAssertTrue(halfway.shadow.enabled);
  XCTAssertEqualWithAccuracy(halfway.shadow.red, 0.2, 1e-12);
  XCTAssertEqualWithAccuracy(halfway.shadow.green, 0.3, 1e-12);
  XCTAssertEqualWithAccuracy(halfway.shadow.blue, 0.4, 1e-12);
  XCTAssertEqualWithAccuracy(halfway.shadow.alpha, 0.3, 1e-12);
  XCTAssertEqualWithAccuracy(halfway.shadow.offsetX, 3, 1e-12);
  XCTAssertEqualWithAccuracy(halfway.shadow.offsetY, 4, 1e-12);
  XCTAssertEqualWithAccuracy(halfway.shadow.blurRadius, 32, 1e-12);
  XCTAssertEqualWithAccuracy(halfway.shadow.spreadDistance, 5, 1e-12);
}

@end
