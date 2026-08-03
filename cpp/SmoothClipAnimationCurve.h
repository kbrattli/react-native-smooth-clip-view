#pragma once

#include "SmoothClipRegistry.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <utility>
#include <vector>

// Shared animation math for the Android integrator and the iOS CoreAnimation
// restart paths: frame-clock anchoring, timing curves/remainders, spring
// continuation, presentation blending and keyframes. Keeping the pure math out
// of the registry translation units also lets the XCTest binary pin every rule
// below — see ios/tests/SmoothClipAnimationCurveTests.mm.
namespace smoothclip {

inline double clamp01(double value) {
  return std::min(1.0, std::max(0.0, value));
}

// --- Frame clock ----------------------------------------------------------

// Moves a wall-clock start stamp onto the choreographer frame-time axis by
// taking the EARLIER of the two stamps.
//
// This is Reanimated's own rule, which is what keeps a parallel `withTiming`
// and the native clip at the same phase: `valueSetter.ts` stamps `startTime`
// with `global.__frameTimestamp || _getAnimationTimestamp()`, and `min()`
// reproduces both branches — a call issued between frames keeps its wall stamp
// (the dispatching frame is later, so the first fraction is already positive
// and no start frame is duplicated), while a call issued inside the frame that
// dispatches us adopts that frame's stamp.
//
// Deliberately NOT a wall-elapsed rebase (`frameNow - (wallNow - startedAt)`):
// that bakes the first frame's intra-frame dispatch latency into the curve for
// the animation's whole duration.
//
// Both arguments must be CLOCK_MONOTONIC seconds. This compares them
// absolutely, so a shared epoch is load-bearing — see nowSeconds() in the
// Android registry for what breaks if that ever stops holding.
//
// min() is an APPROXIMATION of Reanimated's rule that reads no JS state, and
// it has one wrong branch: a start issued from an earlier phase of a frame
// already in flight (CALLBACK_INPUT — batched gesture moves) is dispatched in
// that same doFrame, whose stamp is EARLIER than the call. min() adopts the
// frame stamp while Reanimated — outside its rAF flush, where
// __frameTimestamp is cleared — keeps its wall stamp, so the clip led a
// parallel Reanimated animation by the callback's intra-frame offset for the
// whole duration. Starts that carry the JS-captured stamp resolve through
// resolveStartStamp() below and skip this anchor entirely; min() remains for
// latch flushes and stamp-less callers, where its two branches are exact.
inline double anchorStartTime(double startedAtS, double frameNowS) {
  return std::min(startedAtS, frameNowS);
}

// A resolved start stamp for a new animation.
struct StartStamp {
  double startedAtS;
  // True when startedAtS already lives on Reanimated's own start axis (the
  // JS side captured `__frameTimestamp || _getAnimationTimestamp()` in the
  // same worklet that issued the animateTo), so the first advance() must NOT
  // re-anchor it with min() — see the CALLBACK_INPUT note on
  // anchorStartTime().
  bool frameClockAnchored;
};

// How far a JS-captured stamp may sit from the native wall clock and still be
// trusted. The two reads happen microseconds apart in the same synchronous
// call stack, and a __frameTimestamp hint can lag by at most one stalled
// frame; a full second means a broken epoch (a caller stamping from the wrong
// clock), where falling back to the native clock is strictly safer than
// completing every animation on its first frame.
inline constexpr double kStartStampSanityWindowS = 1.0;

inline StartStamp resolveStartStamp(double jsStampS, double wallNowS) {
  const bool usable = std::isfinite(jsStampS) &&
      std::abs(jsStampS - wallNowS) <= kStartStampSanityWindowS;
  if (usable) return {jsStampS, true};
  return {wallNowS, false};
}

// Elapsed fraction of a timing/keyframe animation. A non-positive duration is
// complete on its first frame rather than dividing by zero.
inline double timingFraction(
    double nowS,
    double startedAtS,
    double durationS) {
  if (durationS <= 0) return 1.0;
  return clamp01((nowS - startedAtS) / durationS);
}

// --- Timing curve continuation -------------------------------------------

struct CubicBezierPoint {
  double x;
  double y;
};

inline CubicBezierPoint mixBezierPoint(
    CubicBezierPoint from,
    CubicBezierPoint to,
    double progress) {
  return {from.x + (to.x - from.x) * progress,
          from.y + (to.y - from.y) * progress};
}

inline double cubicBezierParameterForX(
    double x1,
    double x2,
    double input,
    int iterations = 14) {
  double low = 0;
  double high = 1;
  // Keep the runtime evaluator's established precision/cost: this same solve
  // runs on every Android timing frame.
  for (int iteration = 0; iteration < iterations; iteration += 1) {
    const double t = (low + high) / 2;
    const double inverse = 1 - t;
    const double x = 3 * inverse * inverse * t * x1 +
        3 * inverse * t * t * x2 + t * t * t;
    if (x < input) {
      low = t;
    } else {
      high = t;
    }
  }
  return (low + high) / 2;
}

inline double cubicBezier(
    double x1,
    double y1,
    double x2,
    double y2,
    double input) {
  const double t = cubicBezierParameterForX(x1, x2, clamp01(input));
  const double inverse = 1 - t;
  return 3 * inverse * inverse * t * y1 +
      3 * inverse * t * t * y2 + t * t * t;
}

struct TimingRemainder {
  TimingAnimation animation;
  double easedProgress;
  bool representable;
};

struct TimingContinuation {
  Presentation start;
  TimingAnimation animation;
};

// Exact right-hand segment of a CSS/CoreAnimation cubic Bezier after a raw
// time cutoff. Restarting the original controls from a frozen presentation
// resets its slope and creates a visible velocity cusp. De Casteljau splitting
// preserves the original curve; normalizing the right segment to (0,0)->(1,1)
// makes it directly reusable with a shorter BasicAnimation/integrator run.
inline TimingRemainder timingRemainder(
    const TimingAnimation &original,
    double rawProgress) {
  const double progress = clamp01(rawProgress);
  if (progress <= 0) return {original, 0, true};
  if (progress >= 1) {
    TimingAnimation complete = original;
    complete.durationMs = 0;
    complete.controlPoint1X = 0;
    complete.controlPoint1Y = 0;
    complete.controlPoint2X = 1;
    complete.controlPoint2Y = 1;
    return {complete, 1, true};
  }

  const double t = cubicBezierParameterForX(
      original.controlPoint1X, original.controlPoint2X, progress, 30);
  const CubicBezierPoint p0{0, 0};
  const CubicBezierPoint p1{
      original.controlPoint1X, original.controlPoint1Y};
  const CubicBezierPoint p2{
      original.controlPoint2X, original.controlPoint2Y};
  const CubicBezierPoint p3{1, 1};
  const CubicBezierPoint a = mixBezierPoint(p0, p1, t);
  const CubicBezierPoint b = mixBezierPoint(p1, p2, t);
  const CubicBezierPoint c = mixBezierPoint(p2, p3, t);
  const CubicBezierPoint d = mixBezierPoint(a, b, t);
  const CubicBezierPoint e = mixBezierPoint(b, c, t);
  const CubicBezierPoint split = mixBezierPoint(d, e, t);

  TimingAnimation remainder = original;
  remainder.durationMs = original.durationMs * (1 - progress);
  const double remainingX = 1 - split.x;
  const double remainingY = 1 - split.y;
  // A curve whose y reaches exactly 1 before its time endpoint and later
  // departs cannot be represented as one endpoint-normalized BasicAnimation.
  // Keep the result finite; ordinary monotone easings never take this branch.
  if (std::abs(remainingX) <= 1e-12 || std::abs(remainingY) <= 1e-12) {
    remainder.controlPoint1X = 0;
    remainder.controlPoint1Y = 0;
    remainder.controlPoint2X = 1;
    remainder.controlPoint2Y = 1;
    return {remainder, split.y, false};
  }
  remainder.controlPoint1X = (e.x - split.x) / remainingX;
  remainder.controlPoint1Y = (e.y - split.y) / remainingY;
  remainder.controlPoint2X = (c.x - split.x) / remainingX;
  remainder.controlPoint2Y = (c.y - split.y) / remainingY;
  return {remainder, split.y, true};
}

// --- Spring continuation --------------------------------------------------

struct NormalizedSpringState {
  // Remaining fraction of the original from->target displacement.
  double remaining;
  // Derivative of `remaining` in units per second.
  double velocity;
};

// Closed-form state of the same mass/spring/damper equation CoreAnimation
// evaluates. If p is animation progress, remaining=1-p starts at 1 and its
// derivative starts at -initialVelocity.
inline NormalizedSpringState normalizedSpringState(
    const SpringAnimation &spring,
    double elapsedS) {
  if (!std::isfinite(elapsedS) || elapsedS <= 0) {
    return {1, -spring.initialVelocity};
  }
  const double mass = spring.mass;
  const double stiffness = spring.stiffness;
  const double damping = spring.damping;
  const double initialVelocity = spring.initialVelocity;
  if (!std::isfinite(mass) || !std::isfinite(stiffness) ||
      !std::isfinite(damping) || !std::isfinite(initialVelocity) ||
      mass <= 0 || stiffness <= 0 || damping < 0) {
    return {1, 0};
  }

  const double alpha = damping / (2 * mass);
  const double omegaSquared = stiffness / mass;
  const double discriminant = alpha * alpha - omegaSquared;
  const double criticalScale = std::max(1.0, omegaSquared);
  if (std::abs(discriminant) <= 1e-12 * criticalScale) {
    const double coefficient = alpha - initialVelocity;
    const double decay = std::exp(-alpha * elapsedS);
    const double remaining = decay * (1 + coefficient * elapsedS);
    const double velocity = decay *
        (coefficient - alpha * (1 + coefficient * elapsedS));
    return {remaining, velocity};
  }
  if (discriminant < 0) {
    const double omega = std::sqrt(-discriminant);
    const double coefficient = (alpha - initialVelocity) / omega;
    const double angle = omega * elapsedS;
    const double cosine = std::cos(angle);
    const double sine = std::sin(angle);
    const double basis = cosine + coefficient * sine;
    const double basisVelocity =
        -omega * sine + coefficient * omega * cosine;
    const double decay = std::exp(-alpha * elapsedS);
    return {decay * basis, decay * (basisVelocity - alpha * basis)};
  }

  const double root = std::sqrt(discriminant);
  const double firstRate = -alpha + root;
  const double secondRate = -alpha - root;
  const double firstCoefficient =
      (-initialVelocity - secondRate) / (firstRate - secondRate);
  const double secondCoefficient = 1 - firstCoefficient;
  const double first = firstCoefficient * std::exp(firstRate * elapsedS);
  const double second = secondCoefficient * std::exp(secondRate * elapsedS);
  return {first + second, firstRate * first + secondRate * second};
}

// CASpringAnimation.initialVelocity is normalized by the current remaining
// distance. Re-expressing the old physical velocity against the frozen
// current->target displacement preserves the derivative at a re-latch seam.
inline double springContinuationVelocity(
    const SpringAnimation &spring,
    double elapsedS) {
  const NormalizedSpringState state = normalizedSpringState(spring, elapsedS);
  if (!std::isfinite(state.remaining) || !std::isfinite(state.velocity) ||
      std::abs(state.remaining) <= 1e-9) {
    return 0;
  }
  const double result = -state.velocity / state.remaining;
  return std::isfinite(result) ? result : 0;
}

// --- Presentation channels ------------------------------------------------

constexpr std::size_t kChannelCount = 7;
using Channels = std::array<double, kChannelCount>;

inline Channels toChannels(const Presentation &presentation) {
  return {presentation.clip.x,
          presentation.clip.y,
          presentation.clip.width,
          presentation.clip.height,
          presentation.clip.radius,
          presentation.contentTranslateX,
          presentation.contentTranslateY};
}

inline Presentation fromChannels(const Channels &channels) {
  return Presentation{
      {channels[0], channels[1], channels[2], channels[3], channels[4]},
      channels[5],
      channels[6]};
}

inline Presentation interpolate(
    const Presentation &from,
    const Presentation &to,
    double progress) {
  const auto mix = [progress](double start, double end) {
    return start + (end - start) * progress;
  };
  return Presentation{
      {mix(from.clip.x, to.clip.x),
       mix(from.clip.y, to.clip.y),
       mix(from.clip.width, to.clip.width),
       mix(from.clip.height, to.clip.height),
       mix(from.clip.radius, to.clip.radius)},
      mix(from.contentTranslateX, to.contentTranslateX),
      mix(from.contentTranslateY, to.contentTranslateY)};
}

// Freezes a timing animation at one already-rendered raw-time phase and
// returns the exact right-hand Bezier segment. Keeping the presentation and
// residual curve in one helper prevents lifecycle code from sampling one
// timestamp for the geometry and another for the duration.
inline TimingContinuation timingContinuation(
    const TimingAnimation &original,
    const Presentation &start,
    const Presentation &target,
    double rawProgress) {
  const TimingRemainder remainder = timingRemainder(original, rawProgress);
  return {
      interpolate(start, target, remainder.easedProgress),
      remainder.animation};
}

// Android lifecycle callbacks can arrive long after the frame whose
// presentation was actually delivered. Keep the clock inputs at this shared
// boundary so callers cannot accidentally trim from callback wall time while
// calculating geometry from the last rendered frame.
inline TimingContinuation timingContinuationAtFrame(
    const TimingAnimation &original,
    const Presentation &start,
    const Presentation &target,
    double lastRenderedS,
    double startedAtS,
    double durationS) {
  return timingContinuation(
      original,
      start,
      target,
      timingFraction(lastRenderedS, startedAtS, durationS));
}

// --- Keyframe curve -------------------------------------------------------

// Keyframes sampled from a smooth path, evaluated with monotone cubic Hermite
// interpolation (Fritsch-Carlson).
//
// Straight lerping between keyframes is exact at every keyframe and wrong in
// between in a way that matters more than its position error suggests: the
// interpolated VELOCITY is a staircase that steps at every keyframe boundary,
// beside content whose Reanimated curve is continuous. Consumers bake dozens of
// keyframes precisely because their geometry path is not affine in progress, so
// reconstructing that path smoothly is the honest reading of their intent.
//
// Monotone rather than plain Catmull-Rom because the alternative can overshoot,
// and these channels do not tolerate it: width, height and radius must never
// dip below zero or bulge past the values the consumer asked for. The
// Fritsch-Carlson tangent clamp keeps every segment inside the range of its own
// endpoints. Two keyframes degenerate to the old straight line (both tangents
// equal the secant) — equal in real arithmetic, within one ulp (~1e-13 of the
// travel) in doubles because the Hermite blend orders its operations
// differently than the lerp it replaced. The jfloat delivery cast erases the
// difference long before a pixel could see it.
//
// PARITY NOTE: iOS builds a CAKeyframeAnimation with `kCAAnimationLinear`
// (SmoothClipView.mm) and cannot run this evaluator — CoreAnimation interpolates
// off-thread. The platforms therefore differ mid-segment by the linearization
// error this removes, sub-pixel at any realistic keyframe density and zero at
// every keyframe. Closing it needs either `kCAAnimationCubic` (a different
// spline that CAN overshoot, so no) or resampling the keyframes densely through
// this curve before handing them to CA.
class KeyframeCurve {
 public:
  void reset(std::vector<Keyframe> frames) {
    frames_ = std::move(frames);
    cursor_ = 1;
    tangents_.assign(frames_.size(), Channels{});
    const std::size_t count = frames_.size();
    if (count < 2) return;

    // Secant slope of every segment, per channel. A non-increasing offset pair
    // (the re-latch remap can produce one) contributes no slope rather than
    // dividing by zero; evaluate() short-circuits those segments too.
    std::vector<Channels> secants(count - 1);
    for (std::size_t index = 0; index + 1 < count; index += 1) {
      const double span = frames_[index + 1].offset - frames_[index].offset;
      const Channels lower = toChannels(frames_[index].presentation);
      const Channels upper = toChannels(frames_[index + 1].presentation);
      for (std::size_t channel = 0; channel < kChannelCount; channel += 1) {
        secants[index][channel] =
            span > 0 ? (upper[channel] - lower[channel]) / span : 0.0;
      }
    }

    // One-sided at the ends, averaged inside.
    for (std::size_t channel = 0; channel < kChannelCount; channel += 1) {
      tangents_[0][channel] = secants[0][channel];
      tangents_[count - 1][channel] = secants[count - 2][channel];
      for (std::size_t index = 1; index + 1 < count; index += 1) {
        tangents_[index][channel] =
            (secants[index - 1][channel] + secants[index][channel]) / 2.0;
      }
    }

    // Fritsch-Carlson clamp: this is what makes the curve non-overshooting.
    for (std::size_t index = 0; index + 1 < count; index += 1) {
      for (std::size_t channel = 0; channel < kChannelCount; channel += 1) {
        const double secant = secants[index][channel];
        if (secant == 0.0) {
          // Flat segment: pin both ends flat so the curve cannot bulge off a
          // pair of equal keyframes.
          tangents_[index][channel] = 0.0;
          tangents_[index + 1][channel] = 0.0;
          continue;
        }
        double alpha = tangents_[index][channel] / secant;
        double beta = tangents_[index + 1][channel] / secant;
        if (alpha < 0.0) {
          tangents_[index][channel] = 0.0;
          alpha = 0.0;
        }
        if (beta < 0.0) {
          tangents_[index + 1][channel] = 0.0;
          beta = 0.0;
        }
        const double magnitude = alpha * alpha + beta * beta;
        if (magnitude > 9.0) {
          const double scale = 3.0 / std::sqrt(magnitude);
          tangents_[index][channel] = scale * alpha * secant;
          tangents_[index + 1][channel] = scale * beta * secant;
        }
      }
    }
  }

  const std::vector<Keyframe> &frames() const { return frames_; }
  std::size_t size() const { return frames_.size(); }
  bool usable() const { return frames_.size() >= 2; }

  Presentation evaluate(double progress) {
    const std::size_t count = frames_.size();
    if (count == 0) return Presentation{{0, 0, 0, 0, 0}, 0, 0};
    if (count == 1) return frames_[0].presentation;

    // The scan resumes from the previous segment instead of restarting at 1.
    // Progress is monotonic within an animation, so this is O(1) amortized
    // where the old restart-every-frame scan was O(keyframes) per frame; the
    // backward walk keeps it correct if progress ever moves the other way.
    std::size_t upper = std::min(std::max<std::size_t>(cursor_, 1), count - 1);
    while (upper > 1 && progress < frames_[upper - 1].offset) upper -= 1;
    while (upper < count - 1 && progress > frames_[upper].offset) upper += 1;
    cursor_ = upper;

    const Keyframe &lower = frames_[upper - 1];
    const Keyframe &higher = frames_[upper];
    const double span = higher.offset - lower.offset;
    if (span <= 0) return higher.presentation;

    const double t = clamp01((progress - lower.offset) / span);
    const double t2 = t * t;
    const double t3 = t2 * t;
    // Cubic Hermite basis.
    const double h00 = 2 * t3 - 3 * t2 + 1;
    const double h10 = t3 - 2 * t2 + t;
    const double h01 = -2 * t3 + 3 * t2;
    const double h11 = t3 - t2;

    const Channels from = toChannels(lower.presentation);
    const Channels to = toChannels(higher.presentation);
    const Channels &fromSlope = tangents_[upper - 1];
    const Channels &toSlope = tangents_[upper];
    Channels blended{};
    for (std::size_t channel = 0; channel < kChannelCount; channel += 1) {
      blended[channel] = h00 * from[channel] +
          h10 * span * fromSlope[channel] + h01 * to[channel] +
          h11 * span * toSlope[channel];
    }
    return fromChannels(blended);
  }

 private:
  std::vector<Keyframe> frames_;
  std::vector<Channels> tangents_;
  std::size_t cursor_ = 1;
};

struct KeyframeContinuation {
  Presentation start;
  std::vector<Keyframe> frames;
  double durationMs;
};

// Trims keyframes at the same raw-time phase that produced `frozen`. The new
// zero frame is the rendered presentation, not an analytically re-sampled
// neighbor, so a pause/re-latch cannot jump at the seam. Strictly increasing
// remapped offsets avoid duplicate/division-by-zero segments after repeated
// trims or floating-point collisions near the cutoff.
inline KeyframeContinuation keyframeContinuation(
    const std::vector<Keyframe> &frames,
    const Presentation &frozen,
    const Presentation &target,
    double durationMs,
    double rawProgress) {
  const double progress = clamp01(rawProgress);
  KeyframeContinuation result{
      frozen, {{0.0, frozen}}, std::max(0.0, durationMs * (1 - progress))};
  if (progress < 1.0) {
    for (const Keyframe &frame : frames) {
      if (frame.offset <= progress) continue;
      const double offset = clamp01(
          (frame.offset - progress) / (1 - progress));
      if (offset <= result.frames.back().offset + 1e-12) continue;
      result.frames.push_back({offset, frame.presentation});
    }
  }
  if (result.frames.size() == 1 ||
      result.frames.back().offset < 1.0 - 1e-12) {
    result.frames.push_back({1.0, target});
  } else {
    result.frames.back().offset = 1.0;
    result.frames.back().presentation = target;
  }
  return result;
}

inline KeyframeContinuation keyframeContinuationAtFrame(
    const std::vector<Keyframe> &frames,
    const Presentation &frozen,
    const Presentation &target,
    double lastRenderedS,
    double startedAtS,
    double durationS) {
  return keyframeContinuation(
      frames,
      frozen,
      target,
      std::max(0.0, durationS * 1000.0),
      timingFraction(lastRenderedS, startedAtS, durationS));
}

} // namespace smoothclip
