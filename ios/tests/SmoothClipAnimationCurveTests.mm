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

// The non-overshoot guarantee is exact in real arithmetic: the Hermite basis
// term -2t^3 + 3t^2 peaks at exactly 1 when t == 1. Evaluating it in doubles
// near that endpoint can round to 1 + 2eps, so an endpoint value comes back a
// few ulps proud of its keyframe. This slack absorbs that and nothing more —
// the overshoot a plain Catmull-Rom spline produces on the shapes below is
// whole units, so it is still caught.
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

#pragma mark - Timing fraction

- (void)testTimingFractionClampsAndCompletesDegenerateDurations {
  XCTAssertEqual(smoothclip::timingFraction(5.0, 1.0, 0.0), 1.0);
  XCTAssertEqual(smoothclip::timingFraction(5.0, 1.0, -1.0), 1.0);
  XCTAssertEqual(smoothclip::timingFraction(0.5, 1.0, 2.0), 0.0);
  XCTAssertEqual(smoothclip::timingFraction(9.0, 1.0, 2.0), 1.0);
  XCTAssertEqualWithAccuracy(
      smoothclip::timingFraction(2.0, 1.0, 2.0), 0.5, 1e-12);
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

- (void)testTwoKeyframesStayExactlyLinear {
  // The degenerate case must be bit-for-bit what the old lerp produced, so a
  // consumer passing a straight segment sees no behavior change at all.
  KeyframeCurve curve;
  curve.reset({{0.0, presentationWithX(10)}, {1.0, presentationWithX(50)}});
  for (double progress = 0; progress <= 1.0; progress += 0.05) {
    XCTAssertEqualWithAccuracy(
        curve.evaluate(progress).clip.x, 10 + 40 * progress, 1e-9);
  }
}

- (void)testCurveNeverOvershootsItsKeyframeRange {
  // The reason this is monotone cubic and not Catmull-Rom: a plain spline
  // overshoots on this shape, and radius/width/height must never leave the
  // range the consumer asked for (a negative radius is not renderable).
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

- (void)testVelocityIsContinuousAcrossAnInteriorKeyframe {
  // This is the whole point of the change. Linear interpolation is exact at
  // every keyframe and has a DIFFERENT slope either side of it, so the
  // rendered velocity steps at each boundary while parallel Reanimated content
  // runs a continuous curve. The cubic's one-sided slopes must agree.
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
  XCTAssertEqualWithAccuracy(
      before, after, std::fabs(before) * 1e-3,
      "monotone cubic Hermite is C1: the tangent at a keyframe is shared");

  // And prove the data really has a kink to smooth — the secants either side
  // differ, which is exactly the staircase the old lerp rendered.
  const double secantBefore =
      (frames[2].presentation.clip.x - frames[1].presentation.clip.x) /
      (frames[2].offset - frames[1].offset);
  const double secantAfter =
      (frames[3].presentation.clip.x - frames[2].presentation.clip.x) /
      (frames[3].offset - frames[2].offset);
  XCTAssertGreaterThan(std::fabs(secantBefore - secantAfter), 1.0);
}

- (void)testCurveTracksTheSampledPathMoreCloselyThanStraightSegments {
  // Sample coarsely so the linearization error is measurable, then compare
  // both reconstructions against the true ease-out-cubic they were sampled
  // from. The cubic must be strictly better, not merely different.
  const double travel = 700;
  const std::vector<Keyframe> frames = easeOutCubicSamples(6, travel);
  KeyframeCurve curve;
  curve.reset(frames);

  double worstCubic = 0;
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

    worstCubic =
        std::max(worstCubic, std::fabs(curve.evaluate(progress).clip.x - truth));
    worstLinear = std::max(worstLinear, std::fabs(linear - truth));
  }
  XCTAssertLessThan(worstCubic, worstLinear);
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

- (void)testProgressOutsideTheCurveClampsToItsEndpoints {
  KeyframeCurve curve;
  curve.reset({{0.0, presentationWithX(10)}, {1.0, presentationWithX(50)}});
  XCTAssertEqualWithAccuracy(curve.evaluate(-5.0).clip.x, 10.0, 1e-9);
  XCTAssertEqualWithAccuracy(curve.evaluate(5.0).clip.x, 50.0, 1e-9);
}

@end
