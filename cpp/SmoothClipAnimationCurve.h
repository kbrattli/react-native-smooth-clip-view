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

// The first eleven channels are geometry/content; the final eight are shadow.
// Curve and shadow presence are categorical and stay outside the scalar array.
constexpr std::size_t kBaseChannelCount = 11;
constexpr std::size_t kChannelCount = 19;
using Channels = std::array<double, kChannelCount>;

inline double resolvedRadius(double overrideValue, double shorthand) {
  return std::isfinite(overrideValue) ? overrideValue : shorthand;
}

inline bool radiiAreUniform(
    double topLeft,
    double topRight,
    double bottomRight,
    double bottomLeft) {
  return topLeft == topRight && topLeft == bottomRight &&
      topLeft == bottomLeft;
}

inline Channels toChannels(const Presentation &presentation) {
  const double topLeft = resolvedRadius(
      presentation.clip.topLeftRadius, presentation.clip.radius);
  const double topRight = resolvedRadius(
      presentation.clip.topRightRadius, presentation.clip.radius);
  const double bottomRight = resolvedRadius(
      presentation.clip.bottomRightRadius, presentation.clip.radius);
  const double bottomLeft = resolvedRadius(
      presentation.clip.bottomLeftRadius, presentation.clip.radius);
  return {presentation.clip.x,
          presentation.clip.y,
          presentation.clip.width,
          presentation.clip.height,
          topLeft,
          topRight,
          bottomRight,
          bottomLeft,
          presentation.contentTranslateX,
          presentation.contentTranslateY,
          presentation.contentScale,
          presentation.shadow.red,
          presentation.shadow.green,
          presentation.shadow.blue,
          presentation.shadow.alpha,
          presentation.shadow.offsetX,
          presentation.shadow.offsetY,
          presentation.shadow.blurRadius,
          presentation.shadow.spreadDistance};
}

// --- Animation validation ---------------------------------------------------
//
// Keep the invariants at the native ownership boundary as well as in JS. OTA
// callers and direct host-function users can bypass the TypeScript preflight;
// rejecting here prevents an invalid request from dissolving an existing
// animation group before the registry notices it cannot install the new plan.

inline bool isSupportedCurve(ClipCurve curve) {
  return curve == ClipCurve::Circular || curve == ClipCurve::Continuous;
}

inline bool isFinitePresentation(
    const Presentation &presentation) {
  const Channels channels = toChannels(presentation);
  return std::all_of(
             channels.begin(), channels.end(),
             [](double value) { return std::isfinite(value); }) &&
      isSupportedCurve(presentation.clip.curve) &&
      presentation.contentScale > 0 &&
      presentation.shadow.red >= 0 && presentation.shadow.red <= 1 &&
      presentation.shadow.green >= 0 && presentation.shadow.green <= 1 &&
      presentation.shadow.blue >= 0 && presentation.shadow.blue <= 1 &&
      presentation.shadow.alpha >= 0 && presentation.shadow.alpha <= 1 &&
      presentation.shadow.blurRadius >= 0;
}

inline bool presentationsEqual(
    const Presentation &first,
    const Presentation &second) {
  return first.clip.curve == second.clip.curve &&
      first.shadow.enabled == second.shadow.enabled &&
      toChannels(first) == toChannels(second);
}

inline bool isValidReduceMotionCode(int32_t value) {
  return value >= 0 && value <= 2;
}

inline bool isValidTiming(const TimingAnimation &animation) {
  return std::isfinite(animation.durationMs) && animation.durationMs >= 0 &&
      std::isfinite(animation.controlPoint1X) &&
      std::isfinite(animation.controlPoint1Y) &&
      std::isfinite(animation.controlPoint2X) &&
      std::isfinite(animation.controlPoint2Y) &&
      animation.controlPoint1X >= 0 && animation.controlPoint1X <= 1 &&
      animation.controlPoint2X >= 0 && animation.controlPoint2X <= 1 &&
      isValidReduceMotionCode(animation.reduceMotion);
}

inline bool isValidSpring(const SpringAnimation &animation) {
  return std::isfinite(animation.mass) && animation.mass > 0 &&
      std::isfinite(animation.stiffness) && animation.stiffness > 0 &&
      std::isfinite(animation.damping) && animation.damping >= 0 &&
      std::isfinite(animation.initialVelocity) &&
      isValidReduceMotionCode(animation.reduceMotion);
}

inline bool springScaleIsProvablyPositive(
    const Presentation &start,
    const Presentation &target,
    const SpringAnimation &animation) {
  if (start.contentScale == target.contentScale) return true;
  // With zero initial velocity, a critically/over-damped unit response is
  // monotone, so it remains between two positive endpoints. Inherited or
  // under-damped velocity can overshoot through zero and must be compiled to
  // keyframes by the caller.
  return !animation.inheritVelocity && animation.initialVelocity == 0 &&
      animation.damping * animation.damping >=
      4 * animation.mass * animation.stiffness;
}

inline bool isValidKeyframes(
    const std::vector<Keyframe> &keyframes,
    const Presentation &resolvedStart,
    const Presentation &target,
    bool requireExplicitStart) {
  if (keyframes.size() < 2 || keyframes.front().offset != 0 ||
      keyframes.back().offset != 1 ||
      !presentationsEqual(keyframes.back().presentation, target)) {
    return false;
  }
  if (requireExplicitStart && !presentationsEqual(
                                  keyframes.front().presentation,
                                  resolvedStart)) {
    return false;
  }
  double previousOffset = -1;
  for (const Keyframe &keyframe : keyframes) {
    if (!std::isfinite(keyframe.offset) || keyframe.offset <= previousOffset ||
        keyframe.offset < 0 || keyframe.offset > 1 ||
        !isFinitePresentation(keyframe.presentation) ||
        keyframe.presentation.clip.curve != target.clip.curve) {
      return false;
    }
    previousOffset = keyframe.offset;
  }
  return resolvedStart.clip.curve == target.clip.curve;
}

inline Presentation fromChannels(
    const Channels &channels,
    ClipCurve curve = ClipCurve::Circular,
    bool shadowEnabled = false) {
  Geometry geometry{
      channels[0], channels[1], channels[2], channels[3], 0.0};
  geometry.topLeftRadius = channels[4];
  geometry.topRightRadius = channels[5];
  geometry.bottomRightRadius = channels[6];
  geometry.bottomLeftRadius = channels[7];
  geometry.radius = radiiAreUniform(
      channels[4], channels[5], channels[6], channels[7])
      ? channels[4]
      : 0.0;
  geometry.curve = curve;
  Shadow shadow{
      shadowEnabled,
      std::clamp(channels[11], 0.0, 1.0),
      std::clamp(channels[12], 0.0, 1.0),
      std::clamp(channels[13], 0.0, 1.0),
      std::clamp(channels[14], 0.0, 1.0),
      channels[15],
      channels[16],
      std::max(0.0, channels[17]),
      channels[18]};
  return Presentation{
      geometry, channels[8], channels[9], channels[10], shadow};
}

inline Presentation interpolate(
    const Presentation &from,
    const Presentation &to,
    double progress) {
  const auto mix = [progress](double start, double end) {
    return start + (end - start) * progress;
  };
  Channels blended{};
  const Channels fromChannelsValue = toChannels(from);
  const Channels toChannelsValue = toChannels(to);
  const bool rendersShadow =
      (from.shadow.enabled && from.shadow.alpha > 0) ||
      (to.shadow.enabled && to.shadow.alpha > 0);
  const std::size_t channelCount =
      rendersShadow ? kChannelCount : kBaseChannelCount;
  for (std::size_t index = 0; index < channelCount; index += 1) {
    blended[index] = mix(fromChannelsValue[index], toChannelsValue[index]);
  }
  if (!rendersShadow) {
    std::copy(
        fromChannelsValue.begin() + kBaseChannelCount,
        fromChannelsValue.end(),
        blended.begin() + kBaseChannelCount);
  }
  const bool shadowEnabled = progress >= 1
      ? to.shadow.enabled
      : (from.shadow.enabled || to.shadow.enabled);
  return fromChannels(blended, from.clip.curve, shadowEnabled);
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

// Keyframes interpolate segment-wise linearly on every platform. This is a
// public contract: consumers compile unsupported springs/easings into exact
// scalar samples, and native must not reinterpret those samples as a spline.
class KeyframeCurve {
 public:
  void reset(std::vector<Keyframe> frames) {
    frames_ = std::move(frames);
    cursor_ = 1;
  }

  const std::vector<Keyframe> &frames() const { return frames_; }
  std::size_t size() const { return frames_.size(); }
  bool usable() const { return frames_.size() >= 2; }

  Presentation evaluate(double progress) {
    const std::size_t count = frames_.size();
    if (count == 0) return Presentation{{0, 0, 0, 0, 0}, 0, 0, 1};
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
    return interpolate(lower.presentation, higher.presentation, t);
  }

  private:
  std::vector<Keyframe> frames_;
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
