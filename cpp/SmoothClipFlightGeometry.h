#pragma once

#include "SmoothClipAnimationCurve.h"
#include "SmoothClipRegistry.h"
#include "SmoothClipVelocityTracker.h"

#include <array>
#include <cmath>

// Shared by ios/ and android/: the math behind window-space presentations
// (SmoothClipPresentation.space = 'window') and `velocity: 'inherit'` for
// controller and group springs. A behaviour change here changes both
// platforms. Pinned by ios/tests/SmoothClipFlightGeometryTests.mm.
namespace smoothclip {

// The host's model transform to its window, restricted to what a
// presentation can absorb: a uniform scale and a translation. A host point p
// is drawn at window point scale * p + (translateX, translateY).
struct HostWindowTransform {
  double scale = 1;
  double translateX = 0;
  double translateY = 0;
};

// Classifies an affine host-to-window transform (a b c d tx ty, with
// x' = a x + c y + tx and y' = b x + d y + ty). Rotation, skew and uneven
// scale cannot be expressed by a presentation and are rejected.
inline bool hostWindowTransformFromAffine(
    double a,
    double b,
    double c,
    double d,
    double tx,
    double ty,
    HostWindowTransform &result) {
  constexpr double kTolerance = 1e-6;
  if (!std::isfinite(a) || !std::isfinite(b) || !std::isfinite(c) ||
      !std::isfinite(d) || !std::isfinite(tx) || !std::isfinite(ty)) {
    return false;
  }
  if (std::abs(b) > kTolerance || std::abs(c) > kTolerance ||
      std::abs(a - d) > kTolerance * std::max(1.0, std::abs(a)) ||
      a <= kTolerance) {
    return false;
  }
  result = {a, tx, ty};
  return true;
}

// A window-space presentation describes the frame the host would show if it
// sat unscaled at the window origin. Returns the host-space presentation that
// the host, drawn through `transform`, shows at exactly that window frame.
//
// With c the host's centre (hostWidth / 2, hostHeight / 2), the library maps
// content point p to c + contentScale * (p - c) + contentTranslate. Solving
// transform(hostContent(p)) == windowContent(p) for every p gives
//   contentScale_h     = contentScale_w / s
//   contentTranslate_h = (c * (1 - s) + contentTranslate_w - T) / s
// and every length (clip rect, radii, shadow geometry, backdrop translation)
// divides by s after removing T from positions. Rotation and opacity are
// unchanged: a uniform scale and a translation commute with a rotation about
// the aperture centre.
inline Presentation presentationFromWindowSpace(
    const Presentation &window,
    const HostWindowTransform &transform,
    double hostWidth,
    double hostHeight) {
  const double s = transform.scale;
  const double centreX = hostWidth / 2;
  const double centreY = hostHeight / 2;
  Presentation host = window;
  host.clip.x = (window.clip.x - transform.translateX) / s;
  host.clip.y = (window.clip.y - transform.translateY) / s;
  host.clip.width = window.clip.width / s;
  host.clip.height = window.clip.height / s;
  host.clip.radius = window.clip.radius / s;
  const auto scaled = [s](double value) {
    return std::isfinite(value) ? value / s : value;
  };
  host.clip.topLeftRadius = scaled(window.clip.topLeftRadius);
  host.clip.topRightRadius = scaled(window.clip.topRightRadius);
  host.clip.bottomRightRadius = scaled(window.clip.bottomRightRadius);
  host.clip.bottomLeftRadius = scaled(window.clip.bottomLeftRadius);
  host.contentScale = window.contentScale / s;
  host.contentTranslateX =
      (centreX * (1 - s) + window.contentTranslateX - transform.translateX) / s;
  host.contentTranslateY =
      (centreY * (1 - s) + window.contentTranslateY - transform.translateY) / s;
  host.shadow.offsetX = window.shadow.offsetX / s;
  host.shadow.offsetY = window.shadow.offsetY / s;
  host.shadow.blurRadius = window.shadow.blurRadius / s;
  host.shadow.spreadDistance = window.shadow.spreadDistance / s;
  host.backdropTranslateX = window.backdropTranslateX / s;
  host.backdropTranslateY = window.backdropTranslateY / s;
  return host;
}

// The eleven geometry/content scalars VelocitySampleHistory records.
inline std::array<double, 11> velocitySampleChannels(
    const Presentation &presentation) {
  const Channels channels = toChannels(presentation);
  return {channels[0], channels[1], channels[2], channels[3], channels[4],
          channels[5], channels[6], channels[7], channels[8], channels[9],
          channels[10]};
}

// Normalized progress and its rate (per second) of a run `elapsedS` after its
// epoch. Timing runs differentiate the eased curve numerically; springs
// integrate the same scalar spring both platforms animate with.
struct RunProgress {
  double progress;
  double velocity;
};

inline RunProgress timingRunProgress(
    const TimingAnimation &timing,
    double elapsedS) {
  const double durationS = timing.durationMs / 1000.0;
  if (!(durationS > 0) || elapsedS >= durationS) return {1, 0};
  if (elapsedS < 0) return {0, 0};
  // Solve the curve parameter precisely (the per-frame evaluator's 14
  // bisection steps are ~1e-4 coarse) and differentiate analytically:
  // dProgress/dTime = (dy/dt) / (dx/dt) / duration.
  const double x = elapsedS / durationS;
  const double t = cubicBezierParameterForX(
      timing.controlPoint1X, timing.controlPoint2X, x, 48);
  const auto bezier = [](double p1, double p2, double s) {
    const double u = 1 - s;
    return 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s;
  };
  const auto derivative = [](double p1, double p2, double s) {
    const double u = 1 - s;
    return 3 * u * u * p1 + 6 * u * s * (p2 - p1) + 3 * s * s * (1 - p2);
  };
  const double progress =
      bezier(timing.controlPoint1Y, timing.controlPoint2Y, t);
  const double dx = derivative(timing.controlPoint1X, timing.controlPoint2X, t);
  const double dy = derivative(timing.controlPoint1Y, timing.controlPoint2Y, t);
  const double velocity = dx > 1e-9 ? dy / dx / durationS : 0;
  return {progress, std::isfinite(velocity) ? velocity : 0};
}

inline RunProgress springRunProgress(
    const SpringAnimation &spring,
    double elapsedS) {
  ScalarSpringState state{0, spring.initialVelocity};
  double remaining = std::max(0.0, elapsedS);
  // Fixed small steps keep the analytic stepper exact per step; ten seconds
  // of spring is 600 steps, well within budget for a one-off inherit.
  constexpr double kStepS = 1.0 / 60.0;
  int guard = 0;
  while (remaining > 0 && guard < 2000) {
    const double step = std::min(kStepS, remaining);
    state = advanceScalarSpring(state, spring, step);
    remaining -= step;
    guard += 1;
  }
  return {state.position, state.velocity};
}

// The scalar spring Core Animation runs (iOS's CASpringAnimation): the same
// as springRunProgress up to critical damping. Above it, Core Animation
// follows the physical overdamped solution, where the shared stepper keeps
// Reanimated's critical branch.
inline RunProgress coreAnimationSpringRunProgress(
    const SpringAnimation &spring,
    double elapsedS) {
  const double omega = std::sqrt(spring.stiffness / spring.mass);
  const double zeta =
      spring.damping / (2 * std::sqrt(spring.stiffness * spring.mass));
  if (!(zeta > 1)) return springRunProgress(spring, elapsedS);
  const double t = std::max(0.0, elapsedS);
  const double root = std::sqrt(zeta * zeta - 1);
  const double slow = -omega / (zeta + root);
  const double fast = -omega * (zeta + root);
  // x(t) = 1 + a e^(slow t) + b e^(fast t), with x(0) = 0, x'(0) = v0.
  const double a = (spring.initialVelocity + fast) / (slow - fast);
  const double b = -1 - a;
  const double slowTerm = std::exp(slow * t);
  const double fastTerm = std::exp(fast * t);
  return {
      1 + a * slowTerm + b * fastTerm,
      a * slow * slowTerm + b * fast * fastTerm,
  };
}

// The `velocity: 'inherit'` scalar for a run that replaces a moving one: the
// replaced run's instantaneous velocity (start -> end at `run`), projected
// onto the new run's displacement from where the host is now to `target`.
// Same units and projection as interactive inheritance (inheritedVelocity):
// 1 covers the remaining distance in one second.
inline double inheritedRunVelocity(
    const Presentation &start,
    const Presentation &end,
    RunProgress run,
    const Presentation &target) {
  if (!std::isfinite(run.velocity) || run.velocity == 0) return 0;
  constexpr double kSampleS = 1.0 / 240.0;
  VelocitySampleHistory history;
  history.hasPrevious = true;
  history.hasLatest = true;
  history.previousTimeS = 0;
  history.latestTimeS = kSampleS;
  history.previous = velocitySampleChannels(
      interpolate(start, end, run.progress - run.velocity * kSampleS));
  history.latest =
      velocitySampleChannels(interpolate(start, end, run.progress));
  return inheritedVelocity(
      history, velocitySampleChannels(target), history.latestTimeS);
}

// inheritedRunVelocity for a new run that starts at `from` rather than where
// the replaced run is now (an explicit `from`, or the frame a platform froze
// the run at): the same instantaneous velocity, projected onto the new run's
// own displacement, from -> target. The new run moves each channel at
// scalar * (target - from) per second, so this is the scalar whose motion is
// closest to the replaced run's.
inline double inheritedRunVelocityFrom(
    const Presentation &start,
    const Presentation &end,
    RunProgress run,
    const Presentation &from,
    const Presentation &target) {
  if (!std::isfinite(run.velocity) || run.velocity == 0) return 0;
  constexpr double kSampleS = 1.0 / 240.0;
  const std::array<double, 11> before = velocitySampleChannels(
      interpolate(start, end, run.progress - run.velocity * kSampleS));
  const std::array<double, 11> now =
      velocitySampleChannels(interpolate(start, end, run.progress));
  VelocitySampleHistory history;
  history.hasPrevious = true;
  history.hasLatest = true;
  history.previousTimeS = 0;
  history.latestTimeS = kSampleS;
  history.latest = velocitySampleChannels(from);
  for (std::size_t index = 0; index < history.latest.size(); index += 1) {
    history.previous[index] =
        history.latest[index] - (now[index] - before[index]);
  }
  return inheritedVelocity(
      history, velocitySampleChannels(target), history.latestTimeS);
}

} // namespace smoothclip
