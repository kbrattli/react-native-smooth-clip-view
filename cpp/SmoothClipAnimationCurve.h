#pragma once

#include "SmoothClipRegistry.h"
#include "SmoothClipSharedGeometry.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <utility>
#include <vector>

// Shared animation math for the Android integrator: frame-clock anchoring,
// timing curves, spring validation, and presentation blending. Keeping the pure math out
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
// pre-ready starts and unstamped callers, where its two branches are exact.
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

// Elapsed fraction of a timing animation. A non-positive duration is
// complete on its first frame rather than dividing by zero.
inline double timingFraction(
    double nowS,
    double startedAtS,
    double durationS) {
  if (durationS <= 0) return 1.0;
  return clamp01((nowS - startedAtS) / durationS);
}

// --- Timing curve --------------------------------------------------------

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

/** Canonicalizes registry geometry without consulting any attached host. */
inline bool canonicalizePresentation(Presentation &presentation) {
  if (!isFinitePresentation(presentation)) return false;
  CanonicalClip clip;
  if (!SmoothClipCanonicalize(presentation.clip, clip)) return false;
  presentation.clip = SmoothClipGeometry(clip);
  return true;
}

inline bool presentationsEqual(
    const Presentation &first,
    const Presentation &second) {
  return first.clip.curve == second.clip.curve &&
      first.shadow.enabled == second.shadow.enabled &&
      toChannels(first) == toChannels(second);
}

inline bool hasVisibleShadow(const Presentation &presentation) {
  return presentation.shadow.enabled && presentation.shadow.alpha > 0 &&
      presentation.clip.width > 0 && presentation.clip.height > 0;
}

inline bool isAutonomousUniformCircular(
    const Presentation &presentation) {
  const Geometry &clip = presentation.clip;
  return clip.curve == ClipCurve::Circular && radiiAreUniform(
      resolvedRadius(clip.topLeftRadius, clip.radius),
      resolvedRadius(clip.topRightRadius, clip.radius),
      resolvedRadius(clip.bottomRightRadius, clip.radius),
      resolvedRadius(clip.bottomLeftRadius, clip.radius));
}

/**
 * Makes shadow appearance/disappearance a pure alpha fade. A disabled or
 * transparent endpoint borrows the visible endpoint's style while retaining
 * its own geometry, so path, blur, spread, and offset do not collapse during
 * the fade. The public target remains unchanged in the registry; these copies
 * are animation inputs only.
 */
inline std::pair<Presentation, Presentation> normalizeShadowEndpoints(
    Presentation from,
    Presentation to) {
  const bool fromVisible = hasVisibleShadow(from);
  const bool toVisible = hasVisibleShadow(to);
  if (!fromVisible) from.shadow.alpha = 0;
  if (!toVisible) to.shadow.alpha = 0;
  if (fromVisible == toVisible) return {from, to};

  Shadow &invisible = fromVisible ? to.shadow : from.shadow;
  const Shadow &visible = fromVisible ? from.shadow : to.shadow;
  invisible = visible;
  invisible.enabled = true;
  invisible.alpha = 0;
  return {from, to};
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
      std::isfinite(animation.energyThreshold) &&
      animation.energyThreshold > 0 &&
      isValidReduceMotionCode(animation.reduceMotion);
}

struct ScalarSpringState {
  double position;
  double velocity;
};

/** One analytic Reanimated-compatible spring step for normalized progress. */
inline ScalarSpringState advanceScalarSpring(
    ScalarSpringState state,
    const SpringAnimation &animation,
    double deltaTimeS) {
  const double dt = std::clamp(deltaTimeS, 0.0, 0.064);
  if (dt == 0) return state;
  const double omega0 = std::sqrt(animation.stiffness / animation.mass);
  const double zeta = animation.damping /
      (2.0 * std::sqrt(animation.stiffness * animation.mass));
  const double displacement = state.position - 1.0;
  const double velocity = state.velocity;
  if (zeta < 1.0) {
    const double omega1 = omega0 * std::sqrt(1.0 - zeta * zeta);
    const double envelope = std::exp(-zeta * omega0 * dt);
    const double sinTerm = std::sin(omega1 * dt);
    const double cosTerm = std::cos(omega1 * dt);
    const double coefficient =
        (velocity + zeta * omega0 * displacement) / omega1;
    const double nextDisplacement =
        envelope * (displacement * cosTerm + coefficient * sinTerm);
    const double nextVelocity = envelope *
        (velocity * (cosTerm - zeta * omega0 / omega1 * sinTerm) -
         displacement * (omega0 * omega0 / omega1) * sinTerm);
    return {1.0 + nextDisplacement, nextVelocity};
  }

  // Reanimated deliberately uses its critical branch for zeta >= 1.
  const double envelope = std::exp(-omega0 * dt);
  const double coefficient = velocity + omega0 * displacement;
  const double nextDisplacement =
      envelope * (displacement + coefficient * dt);
  const double nextVelocity =
      envelope * (velocity - omega0 * coefficient * dt);
  return {1.0 + nextDisplacement, nextVelocity};
}

inline double relativeSpringEnergy(
    ScalarSpringState state,
    const SpringAnimation &animation) {
  const double displacement = state.position - 1.0;
  const double currentEnergy =
      animation.mass * state.velocity * state.velocity +
      animation.stiffness * displacement * displacement;
  const double initialEnergy =
      animation.mass * animation.initialVelocity * animation.initialVelocity +
      animation.stiffness;
  return currentEnergy / initialEnergy;
}

inline bool springScaleStaysPositive(
    const Presentation &start,
    const Presentation &target,
    const SpringAnimation &animation,
    double initialVelocity) {
  if (start.contentScale == target.contentScale) return true;
  if (!std::isfinite(initialVelocity)) return false;

  const double startScale = start.contentScale;
  const double targetScale = target.contentScale;
  const double delta = targetScale - startScale;
  const auto scaleForDisplacement = [&](double displacement) {
    // displacement is q = progress - 1, so scale = target + delta*q.
    return targetScale + delta * displacement;
  };
  if (startScale <= 0 || targetScale <= 0) return false;

  const double naturalFrequency =
      std::sqrt(animation.stiffness / animation.mass);
  const double decay = animation.damping / (2 * animation.mass);
  const double discriminant = decay * decay -
      naturalFrequency * naturalFrequency;
  constexpr double epsilon = 1e-12;
  constexpr double pi = 3.14159265358979323846;

  const auto isPositiveAt = [&](double time, double displacement) {
    return time <= epsilon || scaleForDisplacement(displacement) > 0;
  };

  if (discriminant < -epsilon) {
    const double frequency = std::sqrt(-discriminant);
    const double a = -1;
    const double b = (initialVelocity - decay) / frequency;
    const double derivativeCos = initialVelocity;
    const double derivativeSin = frequency - decay * b;
    double phase = std::atan2(-derivativeCos, derivativeSin);
    while (phase <= epsilon) phase += pi;
    // Extrema alternate and their envelope only decays, so the first two
    // positive extrema cover both signs and therefore the global minimum.
    for (int index = 0; index < 2; index += 1) {
      const double time = phase / frequency;
      const double displacement = std::exp(-decay * time) *
          (a * std::cos(phase) + b * std::sin(phase));
      if (!isPositiveAt(time, displacement)) return false;
      phase += pi;
    }
    return true;
  }

  if (std::abs(discriminant) <= epsilon) {
    const double b = initialVelocity - decay;
    const double denominator = decay * b;
    if (std::abs(denominator) <= epsilon) return true;
    const double time = initialVelocity / denominator;
    if (time <= epsilon) return true;
    const double displacement = std::exp(-decay * time) * (-1 + b * time);
    return isPositiveAt(time, displacement);
  }

  const double root = std::sqrt(discriminant);
  const double slow = -decay + root;
  const double fast = -decay - root;
  const double slowCoefficient =
      (initialVelocity + fast) / (slow - fast);
  const double fastCoefficient = -1 - slowCoefficient;
  const double numerator = -fastCoefficient * fast;
  const double denominator = slowCoefficient * slow;
  if (std::abs(denominator) <= epsilon || numerator / denominator <= 0) {
    return true;
  }
  const double time =
      std::log(numerator / denominator) / (slow - fast);
  if (time <= epsilon) return true;
  const double displacement = slowCoefficient * std::exp(slow * time) +
      fastCoefficient * std::exp(fast * time);
  return isPositiveAt(time, displacement);
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
  const auto normalized = normalizeShadowEndpoints(from, to);
  const Channels fromChannelsValue = toChannels(normalized.first);
  const Channels toChannelsValue = toChannels(normalized.second);
  const bool rendersShadow = hasVisibleShadow(from) || hasVisibleShadow(to);
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
      : rendersShadow;
  return fromChannels(blended, from.clip.curve, shadowEnabled);
}

} // namespace smoothclip
