#include "SmoothClipTurboModule.h"

#include "SmoothClipRegistry.h"

#include <cmath>
#include <utility>

namespace facebook::react {
namespace {

constexpr double kMaxSafeJavaScriptInteger = 9007199254740991.0;

bool validDriverId(double value) {
  return std::isfinite(value) && value > 0 &&
      value <= kMaxSafeJavaScriptInteger && std::floor(value) == value;
}

bool finiteGeometry(const smoothclip::Geometry &geometry) {
  return std::isfinite(geometry.x) && std::isfinite(geometry.y) &&
      std::isfinite(geometry.width) && std::isfinite(geometry.height) &&
      std::isfinite(geometry.radius);
}

bool finitePresentation(const smoothclip::Presentation &presentation) {
  return finiteGeometry(presentation.clip) &&
      std::isfinite(presentation.contentTranslateX) &&
      std::isfinite(presentation.contentTranslateY);
}

jsi::Array presentationArray(
    jsi::Runtime &runtime,
    smoothclip::Presentation presentation,
    bool includeHandled = false,
    bool handled = true) {
  const size_t offset = includeHandled ? 1 : 0;
  jsi::Array result(runtime, offset + 7);
  // JS checks `values[0] !== 1`, so the handled flag must be a number: a jsi
  // bool would make every comparison fail and leave the driver stuck in
  // native ownership after cancelAnimation.
  if (includeHandled) result.setValueAtIndex(runtime, 0, handled ? 1.0 : 0.0);
  result.setValueAtIndex(runtime, offset, presentation.clip.x);
  result.setValueAtIndex(runtime, offset + 1, presentation.clip.y);
  result.setValueAtIndex(runtime, offset + 2, presentation.clip.width);
  result.setValueAtIndex(runtime, offset + 3, presentation.clip.height);
  result.setValueAtIndex(runtime, offset + 4, presentation.clip.radius);
  result.setValueAtIndex(runtime, offset + 5, presentation.contentTranslateX);
  result.setValueAtIndex(runtime, offset + 6, presentation.contentTranslateY);
  return result;
}

} // namespace

SmoothClipTurboModule::SmoothClipTurboModule(
    std::shared_ptr<CallInvoker> jsInvoker)
    : NativeSmoothClipModuleCxxSpec(std::move(jsInvoker)) {
  smoothclip::setCompletionCallback(
      this,
      [this](uint64_t driverId, int32_t animationId, bool finished) {
        emitOnClipAnimationComplete(SmoothClipAnimationCompletion{
            static_cast<double>(driverId), animationId, finished});
      });
}

SmoothClipTurboModule::~SmoothClipTurboModule() {
  smoothclip::clearCompletionCallback(this);
}

void SmoothClipTurboModule::setClipPresentation(
    jsi::Runtime &,
    double driverId,
    double x,
    double y,
    double width,
    double height,
    double radius,
    double contentTranslateX,
    double contentTranslateY,
    bool takeOwnership) {
  const smoothclip::Presentation presentation{
      {x, y, width, height, radius}, contentTranslateX, contentTranslateY};
  if (validDriverId(driverId) && finitePresentation(presentation)) {
    smoothclip::setPresentation(
        static_cast<uint64_t>(driverId), presentation, takeOwnership);
  }
}

jsi::Array SmoothClipTurboModule::beginInteraction(
    jsi::Runtime &runtime,
    double driverId) {
  if (!validDriverId(driverId)) {
    return presentationArray(runtime, {{0, 0, 0, 0, 0}, 0, 0});
  }
  return presentationArray(
      runtime,
      smoothclip::beginInteraction(static_cast<uint64_t>(driverId)));
}

int32_t SmoothClipTurboModule::animateTiming(
    jsi::Runtime &,
    double driverId,
    bool hasInteractiveStart,
    double startX,
    double startY,
    double startWidth,
    double startHeight,
    double startRadius,
    double startContentTranslateX,
    double startContentTranslateY,
    double x,
    double y,
    double width,
    double height,
    double radius,
    double contentTranslateX,
    double contentTranslateY,
    double durationMs,
    double controlPoint1X,
    double controlPoint1Y,
    double controlPoint2X,
    double controlPoint2Y,
    int32_t reduceMotion) {
  const smoothclip::Presentation startPresentation{
      {startX, startY, startWidth, startHeight, startRadius},
      startContentTranslateX,
      startContentTranslateY};
  const smoothclip::Presentation presentation{
      {x, y, width, height, radius}, contentTranslateX, contentTranslateY};
  const smoothclip::TimingAnimation animation{
      durationMs,
      controlPoint1X,
      controlPoint1Y,
      controlPoint2X,
      controlPoint2Y,
      reduceMotion};
  if (!validDriverId(driverId) ||
      !finitePresentation(startPresentation) ||
      !finitePresentation(presentation) ||
      !std::isfinite(durationMs) || !std::isfinite(controlPoint1X) ||
      !std::isfinite(controlPoint1Y) || !std::isfinite(controlPoint2X) ||
      !std::isfinite(controlPoint2Y)) return 0;

  return smoothclip::animateTiming(
      static_cast<uint64_t>(driverId),
      {hasInteractiveStart, startPresentation},
      presentation,
      animation);
}

int32_t SmoothClipTurboModule::animateSpring(
    jsi::Runtime &,
    double driverId,
    bool hasInteractiveStart,
    double startX,
    double startY,
    double startWidth,
    double startHeight,
    double startRadius,
    double startContentTranslateX,
    double startContentTranslateY,
    double x,
    double y,
    double width,
    double height,
    double radius,
    double contentTranslateX,
    double contentTranslateY,
    double mass,
    double stiffness,
    double damping,
    double initialVelocity,
    bool inheritVelocity,
    int32_t reduceMotion) {
  const smoothclip::Presentation startPresentation{
      {startX, startY, startWidth, startHeight, startRadius},
      startContentTranslateX,
      startContentTranslateY};
  const smoothclip::Presentation presentation{
      {x, y, width, height, radius}, contentTranslateX, contentTranslateY};
  const smoothclip::SpringAnimation animation{
      mass,
      stiffness,
      damping,
      initialVelocity,
      inheritVelocity,
      reduceMotion};
  if (!validDriverId(driverId) ||
      !finitePresentation(startPresentation) ||
      !finitePresentation(presentation) ||
      !std::isfinite(mass) || !std::isfinite(stiffness) ||
      !std::isfinite(damping) || !std::isfinite(initialVelocity) ||
      mass <= 0 || stiffness <= 0 || damping < 0) return 0;

  return smoothclip::animateSpring(
      static_cast<uint64_t>(driverId),
      {hasInteractiveStart, startPresentation},
      presentation,
      animation);
}

int32_t SmoothClipTurboModule::animateKeyframes(
    jsi::Runtime &runtime,
    double driverId,
    bool hasInteractiveStart,
    double startX,
    double startY,
    double startWidth,
    double startHeight,
    double startRadius,
    double startContentTranslateX,
    double startContentTranslateY,
    double x,
    double y,
    double width,
    double height,
    double radius,
    double contentTranslateX,
    double contentTranslateY,
    double durationMs,
    jsi::Array frames,
    int32_t reduceMotion) {
  const smoothclip::Presentation startPresentation{
      {startX, startY, startWidth, startHeight, startRadius},
      startContentTranslateX,
      startContentTranslateY};
  const smoothclip::Presentation presentation{
      {x, y, width, height, radius}, contentTranslateX, contentTranslateY};
  if (!validDriverId(driverId) ||
      !finitePresentation(startPresentation) ||
      !finitePresentation(presentation) || !std::isfinite(durationMs) ||
      frames.size(runtime) < 16 || frames.size(runtime) % 8 != 0) {
    return 0;
  }

  std::vector<smoothclip::Keyframe> keyframes;
  keyframes.reserve(frames.size(runtime) / 8);
  double previousOffset = -1;
  for (size_t index = 0; index < frames.size(runtime); index += 8) {
    const double offset = frames.getValueAtIndex(runtime, index).asNumber();
    smoothclip::Presentation frame{
        {frames.getValueAtIndex(runtime, index + 1).asNumber(),
         frames.getValueAtIndex(runtime, index + 2).asNumber(),
         frames.getValueAtIndex(runtime, index + 3).asNumber(),
         frames.getValueAtIndex(runtime, index + 4).asNumber(),
         frames.getValueAtIndex(runtime, index + 5).asNumber()},
        frames.getValueAtIndex(runtime, index + 6).asNumber(),
        frames.getValueAtIndex(runtime, index + 7).asNumber()};
    if (!std::isfinite(offset) || offset < 0 || offset > 1 ||
        offset <= previousOffset || !finitePresentation(frame)) return 0;
    previousOffset = offset;
    keyframes.push_back({offset, frame});
  }
  if (keyframes.front().offset != 0 || keyframes.back().offset != 1) return 0;
  return smoothclip::animateKeyframes(
      static_cast<uint64_t>(driverId),
      {hasInteractiveStart, startPresentation},
      presentation,
      durationMs,
      std::move(keyframes),
      reduceMotion);
}

int32_t SmoothClipTurboModule::rejectAnimation(
    jsi::Runtime &,
    double driverId) {
  if (!validDriverId(driverId)) return 0;
  return smoothclip::rejectAnimation(static_cast<uint64_t>(driverId));
}

jsi::Array SmoothClipTurboModule::cancelAnimation(
    jsi::Runtime &runtime,
    double driverId,
    int32_t animationId,
    int32_t behavior) {
  if (!validDriverId(driverId)) {
    return presentationArray(
        runtime, {{0, 0, 0, 0, 0}, 0, 0}, true, false);
  }
  const smoothclip::CancelResult result = smoothclip::cancelAnimation(
      static_cast<uint64_t>(driverId), animationId, behavior == 1);
  return presentationArray(
      runtime, result.presentation, true, result.handled);
}

void SmoothClipTurboModule::destroyDriver(jsi::Runtime &, double driverId) {
  if (validDriverId(driverId)) {
    smoothclip::destroyDriver(static_cast<uint64_t>(driverId));
  }
}

} // namespace facebook::react
