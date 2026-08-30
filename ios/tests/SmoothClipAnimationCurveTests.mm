#import <XCTest/XCTest.h>

#include "SmoothClipAnimationCurve.h"

#include <cmath>
#include <vector>

// Deterministic tests for the shared animation curve (cpp/SmoothClipAnimationCurve.h)
// — the exact code the Android integrator executes every frame for the
// frame-clock anchor, the timing fraction and keyframe evaluation. The Android
// registry translation unit is bound to fbjni and cannot be linked into a test
// binary, so, as with the shared velocity tracker, the behavior is pinned here.
//
// iOS does not evaluate this header at runtime (CoreAnimation drives its own
// animations); it only hosts these tests.

using smoothclip::Keyframe;
using smoothclip::KeyframeCurve;
using smoothclip::Presentation;

namespace {

// Linear interpolation cannot overshoot in real arithmetic. Keep a tiny
// floating-point allowance for endpoint arithmetic.
constexpr double kOvershootSlack = 1e-9;

Presentation presentationWithRadius(double radius) {
  return Presentation{{0, 0, 0, 0, radius}, 0, 0};
}

Presentation presentationWithX(double x) {
  return Presentation{{x, 0, 0, 0, 0}, 0, 0};
}

// Samples an ease-out-cubic path the way a consumer bakes one: uniform time
// offsets, geometry evaluated at the eased progress.
std::vector<Keyframe> easeOutCubicSamples(size_t count, double travel) {
  std::vector<Keyframe> frames;
  frames.reserve(count);
  for (size_t index = 0; index < count; index += 1) {
    const double offset = static_cast<double>(index) / (count - 1);
    const double inverse = 1 - offset;
    const double eased = 1 - inverse * inverse * inverse;
    frames.push_back({offset, presentationWithX(eased * travel)});
  }
  return frames;
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

#pragma mark - Timing remainder

- (void)testTimingRemainderReproducesTheOriginalCurveAfterTheCut {
  const smoothclip::TimingAnimation original{1000, 0.42, 0, 0.58, 1, 2};
  const double cutoff = 0.4;
  const smoothclip::TimingRemainder remainder =
      smoothclip::timingRemainder(original, cutoff);
  XCTAssertTrue(remainder.representable);
  XCTAssertEqualWithAccuracy(remainder.animation.durationMs, 600, 1e-9);

  for (double local = 0; local <= 1; local += 0.05) {
    const double originalValue = smoothclip::cubicBezier(
        original.controlPoint1X,
        original.controlPoint1Y,
        original.controlPoint2X,
        original.controlPoint2Y,
        cutoff + (1 - cutoff) * local);
    const double residualValue = smoothclip::cubicBezier(
        remainder.animation.controlPoint1X,
        remainder.animation.controlPoint1Y,
        remainder.animation.controlPoint2X,
        remainder.animation.controlPoint2Y,
        local);
    const double composed = remainder.easedProgress +
        (1 - remainder.easedProgress) * residualValue;
    XCTAssertEqualWithAccuracy(composed, originalValue, 2e-4);
  }
}

- (void)testTimingRemainderPreservesVelocityAtTheSeam {
  const smoothclip::TimingAnimation original{1000, 0.42, 0, 0.58, 1, 2};
  const double cutoff = 0.4;
  const smoothclip::TimingRemainder remainder =
      smoothclip::timingRemainder(original, cutoff);
  const double t =
      smoothclip::cubicBezierParameterForX(0.42, 0.58, cutoff, 30);
  const double inverse = 1 - t;
  const double dx = 3 * inverse * inverse * 0.42 +
      6 * inverse * t * (0.58 - 0.42) + 3 * t * t * (1 - 0.58);
  const double dy = 6 * inverse * t + 3 * t * t * (1 - 1);
  const double before = dy / dx / original.durationMs;
  const double residualSlope =
      remainder.animation.controlPoint1Y /
      remainder.animation.controlPoint1X;
  const double after = (1 - remainder.easedProgress) * residualSlope /
      remainder.animation.durationMs;
  XCTAssertEqualWithAccuracy(before, after, 1e-9);
  // Restarting the original ease-in-out controls would have zero launch
  // slope, which is the visible cusp this test excludes.
  XCTAssertGreaterThan(after, 1e-4);
}

- (void)testRepeatedTimingTrimMatchesOneDirectTrim {
  const smoothclip::TimingAnimation original{1000, 0.42, 0, 0.58, 1, 2};
  const smoothclip::TimingRemainder first =
      smoothclip::timingRemainder(original, 0.25);
  const smoothclip::TimingRemainder repeated =
      smoothclip::timingRemainder(first.animation, 1.0 / 3.0);
  const smoothclip::TimingRemainder direct =
      smoothclip::timingRemainder(original, 0.5);
  XCTAssertEqualWithAccuracy(
      repeated.animation.durationMs, direct.animation.durationMs, 1e-9);
  XCTAssertEqualWithAccuracy(
      repeated.animation.controlPoint1X,
      direct.animation.controlPoint1X,
      2e-4);
  XCTAssertEqualWithAccuracy(
      repeated.animation.controlPoint1Y,
      direct.animation.controlPoint1Y,
      2e-4);
  XCTAssertEqualWithAccuracy(
      repeated.animation.controlPoint2X,
      direct.animation.controlPoint2X,
      2e-4);
  XCTAssertEqualWithAccuracy(
      repeated.animation.controlPoint2Y,
      direct.animation.controlPoint2Y,
      2e-4);
}

- (void)testTimingContinuationUsesTheLastRenderedTimestamp {
  const smoothclip::TimingAnimation timing{1000, 0.42, 0, 0.58, 1, 2};
  const Presentation start = presentationWithX(0);
  const Presentation target = presentationWithX(100);
  const double startedAt = 10.0;
  const double lastRenderedAt = 10.25;
  const double laterLifecycleCallback = 10.9;

  const smoothclip::TimingContinuation continuation =
      smoothclip::timingContinuationAtFrame(
          timing,
          start,
          target,
          lastRenderedAt,
          startedAt,
          1.0);
  XCTAssertEqualWithAccuracy(continuation.animation.durationMs, 750, 1e-9);
  XCTAssertEqualWithAccuracy(
      continuation.start.clip.x,
      100 * smoothclip::timingRemainder(timing, 0.25).easedProgress,
      1e-9);
  XCTAssertNotEqualWithAccuracy(
      continuation.start.clip.x,
      100 * smoothclip::cubicBezier(
          0.42, 0, 0.58, 1, laterLifecycleCallback - startedAt),
      1.0);
}

- (void)testRepeatedTimingContinuationPreservesTheSameFrozenPhase {
  const smoothclip::TimingAnimation timing{1000, 0.42, 0, 0.58, 1, 2};
  const Presentation start = presentationWithX(0);
  const Presentation target = presentationWithX(100);
  const smoothclip::TimingContinuation first =
      smoothclip::timingContinuation(timing, start, target, 0.25);
  const smoothclip::TimingContinuation repeated =
      smoothclip::timingContinuation(
          first.animation, first.start, target, 0.5);
  XCTAssertEqualWithAccuracy(repeated.animation.durationMs, 375, 1e-9);
  const smoothclip::TimingContinuation direct =
      smoothclip::timingContinuation(timing, start, target, 0.625);
  XCTAssertEqualWithAccuracy(repeated.start.clip.x, direct.start.clip.x, 0.01);
}

#pragma mark - Spring continuation

- (void)testSpringContinuationPreservesPhysicalStateInEveryDampingRegime {
  const double dampings[] = {10, 20, 40}; // under, critical, over for k=100,m=1
  for (double damping : dampings) {
    const smoothclip::SpringAnimation original{
        1, 100, damping, 1.5, false, 2};
    const double cutoff = 0.08;
    const smoothclip::NormalizedSpringState state =
        smoothclip::normalizedSpringState(original, cutoff);
    const double continuation =
        smoothclip::springContinuationVelocity(original, cutoff);
    XCTAssertEqualWithAccuracy(
        state.remaining * continuation, -state.velocity, 1e-10);

    smoothclip::SpringAnimation resumed = original;
    resumed.initialVelocity = continuation;
    const double local = 0.035;
    const smoothclip::NormalizedSpringState resumedState =
        smoothclip::normalizedSpringState(resumed, local);
    const smoothclip::NormalizedSpringState uninterrupted =
        smoothclip::normalizedSpringState(original, cutoff + local);
    XCTAssertEqualWithAccuracy(
        state.remaining * resumedState.remaining,
        uninterrupted.remaining,
        1e-10);
  }
}

- (void)testSpringContinuationAtLaunchEqualsTheRequestedVelocity {
  const smoothclip::SpringAnimation spring{1, 180, 18, 2.25, false, 2};
  XCTAssertEqualWithAccuracy(
      smoothclip::springContinuationVelocity(spring, 0), 2.25, 1e-12);
}

#pragma mark - Keyframe curve

- (void)testCurvePassesThroughEveryKeyframeExactly {
  KeyframeCurve curve;
  curve.reset(easeOutCubicSamples(9, 700));
  for (const Keyframe &frame : curve.frames()) {
    const Presentation value = curve.evaluate(frame.offset);
    XCTAssertEqualWithAccuracy(
        value.clip.x, frame.presentation.clip.x, 1e-9,
        "keyframes are anchors: the curve must not drift off them");
  }
}

- (void)testTwoKeyframesStayLinearWithinFloatingPointTolerance {
  // A two-frame plan is the simplest exact segment-wise-linear case.
  KeyframeCurve curve;
  curve.reset({{0.0, presentationWithX(10)}, {1.0, presentationWithX(50)}});
  for (double progress = 0; progress <= 1.0; progress += 0.05) {
    XCTAssertEqualWithAccuracy(
        curve.evaluate(progress).clip.x, 10 + 40 * progress, 1e-9);
  }
}

- (void)testCurveNeverOvershootsItsKeyframeRange {
  // Exact linear segments stay inside adjacent frame ranges; radii and sizes
  // must never leave the range the consumer supplied.
  KeyframeCurve curve;
  curve.reset({{0.0, presentationWithRadius(0)},
               {1.0 / 3.0, presentationWithRadius(0)},
               {2.0 / 3.0, presentationWithRadius(24)},
               {1.0, presentationWithRadius(24)}});
  for (double progress = 0; progress <= 1.0; progress += 0.005) {
    const double radius = curve.evaluate(progress).clip.radius;
    XCTAssertGreaterThanOrEqual(radius, -kOvershootSlack);
    XCTAssertLessThanOrEqual(radius, 24.0 + kOvershootSlack);
  }
}

- (void)testLocalExtremumDoesNotBulgePastItsKeyframe {
  KeyframeCurve curve;
  curve.reset({{0.0, presentationWithX(0)},
               {0.5, presentationWithX(100)},
               {1.0, presentationWithX(0)}});
  for (double progress = 0; progress <= 1.0; progress += 0.005) {
    const double x = curve.evaluate(progress).clip.x;
    XCTAssertLessThanOrEqual(x, 100.0 + kOvershootSlack);
    XCTAssertGreaterThanOrEqual(x, -kOvershootSlack);
  }
}

- (void)testVelocityUsesTheExactAdjacentSegmentSlopes {
  // V2 keyframes are samples, not spline control points. Native must preserve
  // the exact straight segment on either side of an interior frame, including
  // a deliberate velocity change at that frame.
  const std::vector<Keyframe> frames = easeOutCubicSamples(9, 700);
  KeyframeCurve curve;
  curve.reset(frames);

  const double boundary = frames[2].offset;
  const double epsilon = 1e-6;
  const double before =
      (curve.evaluate(boundary).clip.x - curve.evaluate(boundary - epsilon).clip.x) /
      epsilon;
  const double after =
      (curve.evaluate(boundary + epsilon).clip.x - curve.evaluate(boundary).clip.x) /
      epsilon;
  const double secantBefore =
      (frames[2].presentation.clip.x - frames[1].presentation.clip.x) /
      (frames[2].offset - frames[1].offset);
  const double secantAfter =
      (frames[3].presentation.clip.x - frames[2].presentation.clip.x) /
      (frames[3].offset - frames[2].offset);
  XCTAssertEqualWithAccuracy(before, secantBefore, 1e-3);
  XCTAssertEqualWithAccuracy(after, secantAfter, 1e-3);
  XCTAssertGreaterThan(std::fabs(before - after), 1.0);
}

- (void)testCurveMatchesStraightSegmentReconstructionExactly {
  // Samples are interpolated segment-wise linearly on iOS and Android.
  // Compare the shared evaluator to an independent straight-segment
  // reconstruction across the complete sampled easing.
  const double travel = 700;
  const std::vector<Keyframe> frames = easeOutCubicSamples(6, travel);
  KeyframeCurve curve;
  curve.reset(frames);

  double worstDifference = 0;
  double worstLinear = 0;
  for (double progress = 0; progress <= 1.0; progress += 0.001) {
    const double inverse = 1 - progress;
    const double truth = (1 - inverse * inverse * inverse) * travel;

    size_t upper = 1;
    while (upper < frames.size() - 1 && progress > frames[upper].offset) {
      upper += 1;
    }
    const double span = frames[upper].offset - frames[upper - 1].offset;
    const double local = (progress - frames[upper - 1].offset) / span;
    const double linear = frames[upper - 1].presentation.clip.x +
        (frames[upper].presentation.clip.x -
         frames[upper - 1].presentation.clip.x) *
            local;

    worstDifference = std::max(
        worstDifference,
        std::fabs(curve.evaluate(progress).clip.x - linear));
    worstLinear = std::max(worstLinear, std::fabs(linear - truth));
  }
  XCTAssertLessThan(worstDifference, 1e-9);
  XCTAssertGreaterThan(worstLinear, 0.0);
}

- (void)testCachedSegmentCursorDoesNotChangeResults {
  // evaluate() resumes its segment scan from the previous frame. Walking
  // forward must agree with evaluating each point on a fresh curve, and the
  // cursor must also survive progress moving backwards.
  const std::vector<Keyframe> frames = easeOutCubicSamples(9, 700);
  KeyframeCurve walked;
  walked.reset(frames);

  for (double progress = 0; progress <= 1.0; progress += 0.01) {
    KeyframeCurve fresh;
    fresh.reset(frames);
    XCTAssertEqualWithAccuracy(
        walked.evaluate(progress).clip.x, fresh.evaluate(progress).clip.x, 1e-9);
  }
  for (double progress = 1.0; progress >= 0.0; progress -= 0.01) {
    KeyframeCurve fresh;
    fresh.reset(frames);
    XCTAssertEqualWithAccuracy(
        walked.evaluate(progress).clip.x, fresh.evaluate(progress).clip.x, 1e-9);
  }
}

- (void)testResetRewindsTheCursorForARelatchedRemainder {
  KeyframeCurve curve;
  curve.reset(easeOutCubicSamples(9, 700));
  curve.evaluate(0.95);

  // The re-latch path rewrites the curve in place with the pruned remainder;
  // a cursor left near the end of the old curve would mis-index the new one.
  curve.reset({{0.0, presentationWithX(5)}, {1.0, presentationWithX(9)}});
  XCTAssertEqualWithAccuracy(curve.evaluate(0.0).clip.x, 5.0, 1e-9);
  XCTAssertEqualWithAccuracy(curve.evaluate(0.5).clip.x, 7.0, 1e-9);
}

- (void)testCollidingOffsetsResolveWithoutDividingByZero {
  // The re-latch remap ((offset - progress) / (1 - progress)) can land a frame
  // on top of the prefix at 0 when the animation is caught just before it.
  KeyframeCurve curve;
  curve.reset({{0.0, presentationWithX(3)},
               {0.0, presentationWithX(11)},
               {1.0, presentationWithX(20)}});
  for (double progress = 0; progress <= 1.0; progress += 0.05) {
    const double x = curve.evaluate(progress).clip.x;
    XCTAssertFalse(std::isnan(x));
    XCTAssertGreaterThanOrEqual(x, 3.0);
    XCTAssertLessThanOrEqual(x, 20.0);
  }
}

- (void)testKeyframeContinuationKeepsTheRenderedStartAndUniqueOffsets {
  const Presentation target = presentationWithX(100);
  const std::vector<Keyframe> frames{
      {0.0, presentationWithX(0)},
      {0.25, presentationWithX(20)},
      {0.5, presentationWithX(60)},
      {1.0, target}};
  const smoothclip::KeyframeContinuation continuation =
      smoothclip::keyframeContinuation(
          frames, presentationWithX(23), target, 1000, 0.25);
  XCTAssertEqualWithAccuracy(continuation.start.clip.x, 23, 1e-12);
  XCTAssertEqualWithAccuracy(continuation.durationMs, 750, 1e-12);
  XCTAssertEqual(continuation.frames.size(), 3u);
  XCTAssertEqualWithAccuracy(continuation.frames[0].offset, 0, 1e-12);
  XCTAssertEqualWithAccuracy(
      continuation.frames[1].offset, 1.0 / 3.0, 1e-12);
  XCTAssertEqualWithAccuracy(continuation.frames[2].offset, 1, 1e-12);
  for (size_t index = 1; index < continuation.frames.size(); index += 1) {
    XCTAssertGreaterThan(
        continuation.frames[index].offset,
        continuation.frames[index - 1].offset);
  }
}

- (void)testKeyframeContinuationUsesTheLastRenderedTimestamp {
  const Presentation target = presentationWithX(100);
  const std::vector<Keyframe> frames{
      {0.0, presentationWithX(0)},
      {0.5, presentationWithX(50)},
      {1.0, target}};
  const double startedAt = 10.0;
  const double lastRenderedAt = 10.25;
  const double laterLifecycleCallback = 10.9;

  const smoothclip::KeyframeContinuation continuation =
      smoothclip::keyframeContinuationAtFrame(
          frames,
          presentationWithX(25),
          target,
          lastRenderedAt,
          startedAt,
          1.0);
  XCTAssertEqualWithAccuracy(continuation.durationMs, 750, 1e-9);
  XCTAssertEqualWithAccuracy(continuation.start.clip.x, 25, 1e-12);
  XCTAssertNotEqualWithAccuracy(
      continuation.durationMs,
      1000 * (1 - (laterLifecycleCallback - startedAt)),
      1.0);
}

- (void)testRepeatedKeyframeContinuationAvoidsZeroLengthSegments {
  const Presentation target = presentationWithX(100);
  const smoothclip::KeyframeContinuation first =
      smoothclip::keyframeContinuation(
          {{0, presentationWithX(0)},
           {0.5, presentationWithX(50)},
           {1, target}},
          presentationWithX(25),
          target,
          1000,
          0.25);
  const smoothclip::KeyframeContinuation second =
      smoothclip::keyframeContinuation(
          first.frames,
          presentationWithX(50),
          target,
          first.durationMs,
          1.0 / 3.0);
  XCTAssertEqualWithAccuracy(second.durationMs, 500, 1e-9);
  XCTAssertEqualWithAccuracy(second.frames.front().offset, 0, 1e-12);
  XCTAssertEqualWithAccuracy(second.frames.back().offset, 1, 1e-12);
  for (size_t index = 1; index < second.frames.size(); index += 1) {
    XCTAssertGreaterThan(
        second.frames[index].offset, second.frames[index - 1].offset);
  }
}

- (void)testProgressOutsideTheCurveClampsToItsEndpoints {
  KeyframeCurve curve;
  curve.reset({{0.0, presentationWithX(10)}, {1.0, presentationWithX(50)}});
  XCTAssertEqualWithAccuracy(curve.evaluate(-5.0).clip.x, 10.0, 1e-9);
  XCTAssertEqualWithAccuracy(curve.evaluate(5.0).clip.x, 50.0, 1e-9);
}

@end
