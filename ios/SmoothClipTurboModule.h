#pragma once

#include <SmoothClipViewSpecJSI.h>

namespace facebook::react {

struct SmoothClipAnimationCompletion {
  double driverId;
  int32_t animationId;
  bool finished;
};

template <>
struct Bridging<SmoothClipAnimationCompletion> {
  static SmoothClipAnimationCompletion fromJs(
      jsi::Runtime &runtime,
      const jsi::Object &value) {
    return {
        value.getProperty(runtime, "driverId").asNumber(),
        static_cast<int32_t>(
            value.getProperty(runtime, "animationId").asNumber()),
        value.getProperty(runtime, "finished").getBool()};
  }

  static jsi::Object toJs(
      jsi::Runtime &runtime,
      const SmoothClipAnimationCompletion &value) {
    jsi::Object result(runtime);
    result.setProperty(runtime, "driverId", value.driverId);
    result.setProperty(runtime, "animationId", value.animationId);
    result.setProperty(runtime, "finished", value.finished);
    return result;
  }
};

class SmoothClipTurboModule final
    : public NativeSmoothClipModuleCxxSpec<SmoothClipTurboModule> {
 public:
  explicit SmoothClipTurboModule(std::shared_ptr<CallInvoker> jsInvoker);
  ~SmoothClipTurboModule() override;

  void setClipPresentation(
      jsi::Runtime &runtime,
      double driverId,
      double x,
      double y,
      double width,
      double height,
      double radius,
      double contentTranslateX,
      double contentTranslateY,
      bool takeOwnership);
  jsi::Array beginInteraction(jsi::Runtime &runtime, double driverId);
  int32_t animateTiming(
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
      double controlPoint1X,
      double controlPoint1Y,
      double controlPoint2X,
      double controlPoint2Y,
      int32_t reduceMotion);
  int32_t animateSpring(
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
      double mass,
      double stiffness,
      double damping,
      double initialVelocity,
      bool inheritVelocity,
      int32_t reduceMotion);
  int32_t animateKeyframes(
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
      int32_t reduceMotion);
  int32_t rejectAnimation(jsi::Runtime &runtime, double driverId);
  jsi::Array cancelAnimation(
      jsi::Runtime &runtime,
      double driverId,
      int32_t animationId,
      int32_t behavior);
  void destroyDriver(jsi::Runtime &runtime, double driverId);
};

} // namespace facebook::react
