#pragma once

#include "SmoothClipRegistry.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <utility>
#include <vector>

// Pure animation math for the Android integrator: the frame-clock anchor, the
// timing fraction, presentation blending and the keyframe curve. It lives here
// rather than inside the registry translation unit because that one is bound to
// fbjni and cannot be linked into a test binary — see
// ios/tests/SmoothClipAnimationCurveTests.mm, which pins every rule below.
//
// iOS drives its own animations through CoreAnimation and does not evaluate
// this header at runtime; it only hosts the tests. Any behavior change here is
// therefore Android-only and must be weighed against cross-platform parity.
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

} // namespace smoothclip
