#pragma once

#include <SmoothClipViewSpecJSI.h>

#include <vector>

namespace facebook::react {

struct SmoothClipAnimationCompletion {
  double driverId;
  int32_t animationId;
  int32_t completionTag;
  bool finished;
};

struct SmoothClipGroupAnimationCompletion {
  double controllerId;
  int32_t groupId;
  int32_t completionTag;
  bool finished;
  std::vector<double> snapshots;
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
        static_cast<int32_t>(
            value.getProperty(runtime, "completionTag").asNumber()),
        value.getProperty(runtime, "finished").getBool()};
  }

  static jsi::Object toJs(
      jsi::Runtime &runtime,
      const SmoothClipAnimationCompletion &value) {
    jsi::Object result(runtime);
    result.setProperty(runtime, "driverId", value.driverId);
    result.setProperty(runtime, "animationId", value.animationId);
    result.setProperty(runtime, "completionTag", value.completionTag);
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
        value.getProperty(runtime, "snapshots").asObject(runtime).asArray(runtime);
    std::vector<double> snapshots;
    snapshots.reserve(ids.size(runtime));
    for (size_t index = 0; index < ids.size(runtime); index += 1) {
      snapshots.push_back(ids.getValueAtIndex(runtime, index).asNumber());
    }
    return {
        value.getProperty(runtime, "controllerId").asNumber(),
        static_cast<int32_t>(
            value.getProperty(runtime, "groupId").asNumber()),
        static_cast<int32_t>(
            value.getProperty(runtime, "completionTag").asNumber()),
        value.getProperty(runtime, "finished").getBool(),
        std::move(snapshots),
    };
  }

  static jsi::Object toJs(
      jsi::Runtime &runtime,
      const SmoothClipGroupAnimationCompletion &value) {
    jsi::Object result(runtime);
    result.setProperty(runtime, "controllerId", value.controllerId);
    result.setProperty(runtime, "groupId", value.groupId);
    result.setProperty(runtime, "completionTag", value.completionTag);
    result.setProperty(runtime, "finished", value.finished);
    jsi::Array snapshots(runtime, value.snapshots.size());
    for (size_t index = 0; index < value.snapshots.size(); index += 1) {
      snapshots.setValueAtIndex(runtime, index, value.snapshots[index]);
    }
    result.setProperty(runtime, "snapshots", std::move(snapshots));
    return result;
  }
};

class SmoothClipTurboModule final
    : public NativeSmoothClipModuleCxxSpec<SmoothClipTurboModule> {
 public:
  explicit SmoothClipTurboModule(std::shared_ptr<CallInvoker> jsInvoker);
  ~SmoothClipTurboModule() override;

  bool supportsAutonomousComplexPathAnimation(jsi::Runtime &runtime);
  jsi::Array beginGroupInteraction(
      jsi::Runtime &runtime,
      jsi::Array driverIds);
  jsi::Array snapshotGroup(
      jsi::Runtime &runtime,
      jsi::Array driverIds);
  bool setClipPresentationBatch(
      jsi::Runtime &runtime,
      jsi::Array entries);
  int32_t animateTimingGroup(
      jsi::Runtime &runtime,
      double controllerId,
      jsi::Array entries,
      double durationMs,
      double controlPoint1X,
      double controlPoint1Y,
      double controlPoint2X,
      double controlPoint2Y,
      int32_t reduceMotion,
      int32_t completionTag,
      double startTimestamp);
  int32_t animateSpringGroup(
      jsi::Runtime &runtime,
      double controllerId,
      jsi::Array entries,
      double mass,
      double stiffness,
      double damping,
      double velocity,
      double energyThreshold,
      int32_t reduceMotion,
      int32_t completionTag,
      double startTimestamp);
  jsi::Array cancelAnimationGroup(
      jsi::Runtime &runtime,
      int32_t groupId,
      int32_t behavior);
  void setClipPresentation(
      jsi::Runtime &runtime,
      double driverId,
      jsi::Array presentation,
      bool takeOwnership,
      bool overridePendingAnimation);
  void setClipFrameScalars(
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
      bool shadowEnabled,
      double shadowRed,
      double shadowGreen,
      double shadowBlue,
      double shadowAlpha,
      double shadowOffsetX,
      double shadowOffsetY,
      double shadowBlurRadius,
      double shadowSpreadDistance);
  jsi::Array beginInteraction(jsi::Runtime &runtime, double driverId);
  jsi::Array snapshotCurrent(jsi::Runtime &runtime, double driverId);

  int32_t animateTiming(
      jsi::Runtime &runtime,
      double driverId,
      jsi::Array start,
      jsi::Array target,
      double durationMs,
      double controlPoint1X,
      double controlPoint1Y,
      double controlPoint2X,
      double controlPoint2Y,
      int32_t reduceMotion,
      int32_t completionTag);
  int32_t animateSpring(
      jsi::Runtime &runtime,
      double driverId,
      jsi::Array start,
      jsi::Array target,
      double mass,
      double stiffness,
      double damping,
      double initialVelocity,
      bool inheritVelocity,
      int32_t reduceMotion,
      int32_t completionTag);
  int32_t rejectAnimation(jsi::Runtime &runtime, double driverId);
  jsi::Array cancelAnimation(
      jsi::Runtime &runtime,
      double driverId,
      int32_t animationId,
      int32_t behavior);
  void destroyDriver(jsi::Runtime &runtime, double driverId);
};

} // namespace facebook::react
