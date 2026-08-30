#pragma once

#include <SmoothClipViewSpecJSI.h>

#include <vector>

namespace facebook::react {

struct SmoothClipAnimationCompletion {
  double driverId;
  int32_t animationId;
  bool finished;
};

struct SmoothClipGroupAnimationCompletion {
  double controllerId;
  int32_t groupId;
  bool finished;
  std::vector<double> driverIds;
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

template <>
struct Bridging<SmoothClipGroupAnimationCompletion> {
  static SmoothClipGroupAnimationCompletion fromJs(
      jsi::Runtime &runtime,
      const jsi::Object &value) {
    const jsi::Array ids =
        value.getProperty(runtime, "driverIds").asObject(runtime).asArray(runtime);
    std::vector<double> driverIds;
    driverIds.reserve(ids.size(runtime));
    for (size_t index = 0; index < ids.size(runtime); index += 1) {
      driverIds.push_back(ids.getValueAtIndex(runtime, index).asNumber());
    }
    return {
        value.getProperty(runtime, "controllerId").asNumber(),
        static_cast<int32_t>(
            value.getProperty(runtime, "groupId").asNumber()),
        value.getProperty(runtime, "finished").getBool(),
        std::move(driverIds),
    };
  }

  static jsi::Object toJs(
      jsi::Runtime &runtime,
      const SmoothClipGroupAnimationCompletion &value) {
    jsi::Object result(runtime);
    result.setProperty(runtime, "controllerId", value.controllerId);
    result.setProperty(runtime, "groupId", value.groupId);
    result.setProperty(runtime, "finished", value.finished);
    jsi::Array driverIds(runtime, value.driverIds.size());
    for (size_t index = 0; index < value.driverIds.size(); index += 1) {
      driverIds.setValueAtIndex(runtime, index, value.driverIds[index]);
    }
    result.setProperty(runtime, "driverIds", std::move(driverIds));
    return result;
  }
};

class SmoothClipTurboModule final
    : public NativeSmoothClipModuleCxxSpec<SmoothClipTurboModule> {
 public:
  explicit SmoothClipTurboModule(std::shared_ptr<CallInvoker> jsInvoker);
  ~SmoothClipTurboModule() override;

  int32_t getPresentationProtocolVersion(jsi::Runtime &runtime);
  bool supportsAutonomousComplexPathAnimation(jsi::Runtime &runtime);
  jsi::Array beginGroupInteractionV2(
      jsi::Runtime &runtime,
      jsi::Array driverIds);
  jsi::Array snapshotGroupV2(
      jsi::Runtime &runtime,
      jsi::Array driverIds);
  bool setClipPresentationBatchV2(
      jsi::Runtime &runtime,
      jsi::Array entries);
  int32_t animateTimingGroupV2(
      jsi::Runtime &runtime,
      double controllerId,
      jsi::Array entries,
      double durationMs,
      double controlPoint1X,
      double controlPoint1Y,
      double controlPoint2X,
      double controlPoint2Y,
      int32_t reduceMotion,
      int32_t suspensionPolicy);
  int32_t animateSpringGroupV2(
      jsi::Runtime &runtime,
      double controllerId,
      jsi::Array entries,
      double mass,
      double stiffness,
      double damping,
      double initialVelocity,
      bool inheritVelocity,
      int32_t reduceMotion,
      int32_t suspensionPolicy);
  int32_t animateKeyframesGroupV2(
      jsi::Runtime &runtime,
      double controllerId,
      jsi::Array entries,
      double durationMs,
      int32_t reduceMotion,
      int32_t suspensionPolicy);
  jsi::Array cancelAnimationGroupV2(
      jsi::Runtime &runtime,
      int32_t groupId,
      int32_t behavior);
  void setClipPresentationV2(
      jsi::Runtime &runtime,
      double driverId,
      double x,
      double y,
      double width,
      double height,
      double topLeftRadius,
      double topRightRadius,
      double bottomRightRadius,
      double bottomLeftRadius,
      int32_t curveCode,
      double contentTranslateX,
      double contentTranslateY,
      double contentScale,
      bool takeOwnership,
      bool overridePendingAnimation);
  jsi::Array beginInteractionV2(jsi::Runtime &runtime, double driverId);
  jsi::Array snapshotCurrentV2(jsi::Runtime &runtime, double driverId);

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
      bool takeOwnership,
      bool overridePendingAnimation);
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
  int32_t animateTimingV2(
      jsi::Runtime &runtime,
      double driverId,
      bool hasInteractiveStart,
      double startX,
      double startY,
      double startWidth,
      double startHeight,
      double startTopLeftRadius,
      double startTopRightRadius,
      double startBottomRightRadius,
      double startBottomLeftRadius,
      int32_t startCurveCode,
      double startContentTranslateX,
      double startContentTranslateY,
      double startContentScale,
      double x,
      double y,
      double width,
      double height,
      double topLeftRadius,
      double topRightRadius,
      double bottomRightRadius,
      double bottomLeftRadius,
      int32_t curveCode,
      double contentTranslateX,
      double contentTranslateY,
      double contentScale,
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
  int32_t animateSpringV2(
      jsi::Runtime &runtime,
      double driverId,
      bool hasInteractiveStart,
      double startX,
      double startY,
      double startWidth,
      double startHeight,
      double startTopLeftRadius,
      double startTopRightRadius,
      double startBottomRightRadius,
      double startBottomLeftRadius,
      int32_t startCurveCode,
      double startContentTranslateX,
      double startContentTranslateY,
      double startContentScale,
      double x,
      double y,
      double width,
      double height,
      double topLeftRadius,
      double topRightRadius,
      double bottomRightRadius,
      double bottomLeftRadius,
      int32_t curveCode,
      double contentTranslateX,
      double contentTranslateY,
      double contentScale,
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
  int32_t animateKeyframesV2(
      jsi::Runtime &runtime,
      double driverId,
      bool hasInteractiveStart,
      double startX,
      double startY,
      double startWidth,
      double startHeight,
      double startTopLeftRadius,
      double startTopRightRadius,
      double startBottomRightRadius,
      double startBottomLeftRadius,
      int32_t startCurveCode,
      double startContentTranslateX,
      double startContentTranslateY,
      double startContentScale,
      double x,
      double y,
      double width,
      double height,
      double topLeftRadius,
      double topRightRadius,
      double bottomRightRadius,
      double bottomLeftRadius,
      int32_t curveCode,
      double contentTranslateX,
      double contentTranslateY,
      double contentScale,
      double durationMs,
      jsi::Array frames,
      int32_t reduceMotion);
  int32_t animateTimingFromV2(
      jsi::Runtime &runtime,
      double driverId,
      double startX,
      double startY,
      double startWidth,
      double startHeight,
      double startTopLeftRadius,
      double startTopRightRadius,
      double startBottomRightRadius,
      double startBottomLeftRadius,
      int32_t startCurveCode,
      double startContentTranslateX,
      double startContentTranslateY,
      double startContentScale,
      double x,
      double y,
      double width,
      double height,
      double topLeftRadius,
      double topRightRadius,
      double bottomRightRadius,
      double bottomLeftRadius,
      int32_t curveCode,
      double contentTranslateX,
      double contentTranslateY,
      double contentScale,
      double durationMs,
      double controlPoint1X,
      double controlPoint1Y,
      double controlPoint2X,
      double controlPoint2Y,
      int32_t reduceMotion);
  int32_t animateSpringFromV2(
      jsi::Runtime &runtime,
      double driverId,
      double startX,
      double startY,
      double startWidth,
      double startHeight,
      double startTopLeftRadius,
      double startTopRightRadius,
      double startBottomRightRadius,
      double startBottomLeftRadius,
      int32_t startCurveCode,
      double startContentTranslateX,
      double startContentTranslateY,
      double startContentScale,
      double x,
      double y,
      double width,
      double height,
      double topLeftRadius,
      double topRightRadius,
      double bottomRightRadius,
      double bottomLeftRadius,
      int32_t curveCode,
      double contentTranslateX,
      double contentTranslateY,
      double contentScale,
      double mass,
      double stiffness,
      double damping,
      double initialVelocity,
      bool inheritVelocity,
      int32_t reduceMotion);
  int32_t animateKeyframesFromV2(
      jsi::Runtime &runtime,
      double driverId,
      double startX,
      double startY,
      double startWidth,
      double startHeight,
      double startTopLeftRadius,
      double startTopRightRadius,
      double startBottomRightRadius,
      double startBottomLeftRadius,
      int32_t startCurveCode,
      double startContentTranslateX,
      double startContentTranslateY,
      double startContentScale,
      double x,
      double y,
      double width,
      double height,
      double topLeftRadius,
      double topRightRadius,
      double bottomRightRadius,
      double bottomLeftRadius,
      int32_t curveCode,
      double contentTranslateX,
      double contentTranslateY,
      double contentScale,
      double durationMs,
      jsi::Array frames,
      int32_t reduceMotion);
  int32_t rejectAnimation(jsi::Runtime &runtime, double driverId);
  jsi::Array cancelAnimation(
      jsi::Runtime &runtime,
      double driverId,
      int32_t animationId,
      int32_t behavior);
  jsi::Array cancelAnimationV2(
      jsi::Runtime &runtime,
      double driverId,
      int32_t animationId,
      int32_t behavior);
  void destroyDriver(jsi::Runtime &runtime, double driverId);
};

} // namespace facebook::react
