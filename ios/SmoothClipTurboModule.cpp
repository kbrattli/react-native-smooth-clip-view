#include "SmoothClipTurboModule.h"

#include "SmoothClipAnimationCurve.h"
#include "SmoothClipRegistry.h"
#include "SmoothClipRegistrySnapshot.h"

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

bool validCurveCode(int32_t curveCode) {
  return curveCode == static_cast<int32_t>(smoothclip::ClipCurve::Circular) ||
      curveCode == static_cast<int32_t>(smoothclip::ClipCurve::Continuous);
}

bool validSuspensionPolicy(int32_t value) {
  return value == static_cast<int32_t>(
                      smoothclip::GroupSuspensionPolicy::Pause) ||
      value == static_cast<int32_t>(
                   smoothclip::GroupSuspensionPolicy::Finish);
}

bool numberAt(
    jsi::Runtime &runtime,
    const jsi::Array &array,
    size_t index,
    double &result) {
  if (index >= array.size(runtime)) return false;
  const jsi::Value value = array.getValueAtIndex(runtime, index);
  if (!value.isNumber()) return false;
  result = value.asNumber();
  return std::isfinite(result);
}

smoothclip::Presentation presentationV2(
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
    double contentScale) {
  const bool uniform = topLeftRadius == topRightRadius &&
      topLeftRadius == bottomRightRadius &&
      topLeftRadius == bottomLeftRadius;
  smoothclip::Geometry geometry{
      x, y, width, height, uniform ? topLeftRadius : 0};
  geometry.topLeftRadius = topLeftRadius;
  geometry.topRightRadius = topRightRadius;
  geometry.bottomRightRadius = bottomRightRadius;
  geometry.bottomLeftRadius = bottomLeftRadius;
  geometry.curve = static_cast<smoothclip::ClipCurve>(curveCode);
  return {geometry, contentTranslateX, contentTranslateY, contentScale};
}

bool finitePresentationV2(const smoothclip::Presentation &presentation) {
  const smoothclip::Geometry &geometry = presentation.clip;
  return finiteGeometry(geometry) &&
      std::isfinite(geometry.topLeftRadius) &&
      std::isfinite(geometry.topRightRadius) &&
      std::isfinite(geometry.bottomRightRadius) &&
      std::isfinite(geometry.bottomLeftRadius) &&
      validCurveCode(static_cast<int32_t>(geometry.curve)) &&
      std::isfinite(presentation.contentTranslateX) &&
      std::isfinite(presentation.contentTranslateY) &&
      std::isfinite(presentation.contentScale) &&
      presentation.contentScale > 0;
}

bool presentationV2At(
    jsi::Runtime &runtime,
    const jsi::Array &array,
    size_t offset,
    smoothclip::Presentation &result) {
  double values[12];
  for (size_t index = 0; index < 12; index += 1) {
    if (!numberAt(runtime, array, offset + index, values[index])) {
      return false;
    }
  }
  const int32_t curveCode = static_cast<int32_t>(values[8]);
  if (values[8] != curveCode || !validCurveCode(curveCode)) return false;
  result = presentationV2(
      values[0],
      values[1],
      values[2],
      values[3],
      values[4],
      values[5],
      values[6],
      values[7],
      curveCode,
      values[9],
      values[10],
      values[11]);
  return finitePresentationV2(result);
}

void writePresentationV2(
    jsi::Runtime &runtime,
    jsi::Array &result,
    size_t offset,
    const smoothclip::Presentation &presentation) {
  const smoothclip::Geometry &clip = presentation.clip;
  result.setValueAtIndex(runtime, offset, clip.x);
  result.setValueAtIndex(runtime, offset + 1, clip.y);
  result.setValueAtIndex(runtime, offset + 2, clip.width);
  result.setValueAtIndex(runtime, offset + 3, clip.height);
  result.setValueAtIndex(
      runtime, offset + 4,
      smoothclip::resolvedRadius(clip.topLeftRadius, clip.radius));
  result.setValueAtIndex(
      runtime, offset + 5,
      smoothclip::resolvedRadius(clip.topRightRadius, clip.radius));
  result.setValueAtIndex(
      runtime, offset + 6,
      smoothclip::resolvedRadius(clip.bottomRightRadius, clip.radius));
  result.setValueAtIndex(
      runtime, offset + 7,
      smoothclip::resolvedRadius(clip.bottomLeftRadius, clip.radius));
  result.setValueAtIndex(
      runtime, offset + 8, static_cast<int32_t>(clip.curve));
  result.setValueAtIndex(runtime, offset + 9, presentation.contentTranslateX);
  result.setValueAtIndex(runtime, offset + 10, presentation.contentTranslateY);
  result.setValueAtIndex(runtime, offset + 11, presentation.contentScale);
}

jsi::Array snapshotArrayV2(
    jsi::Runtime &runtime,
    const std::vector<smoothclip::DriverSnapshot> &snapshots) {
  jsi::Array result(runtime, snapshots.size() * 13);
  for (size_t index = 0; index < snapshots.size(); index += 1) {
    const size_t offset = index * 13;
    result.setValueAtIndex(
        runtime, offset, snapshots[index].ready ? 1.0 : 0.0);
    writePresentationV2(
        runtime, result, offset + 1, snapshots[index].presentation);
  }
  return result;
}

bool driverIdsAt(
    jsi::Runtime &runtime,
    const jsi::Array &array,
    std::vector<uint64_t> &result) {
  result.clear();
  result.reserve(array.size(runtime));
  for (size_t index = 0; index < array.size(runtime); index += 1) {
    double driverId = 0;
    if (!numberAt(runtime, array, index, driverId) ||
        !validDriverId(driverId)) {
      return false;
    }
    result.push_back(static_cast<uint64_t>(driverId));
  }
  return true;
}

bool fixedGroupEntriesAt(
    jsi::Runtime &runtime,
    const jsi::Array &array,
    std::vector<smoothclip::GroupMotionEntry> &result) {
  constexpr size_t stride = 26;
  const size_t count = array.size(runtime);
  if (count == 0 || count % stride != 0) return false;
  result.clear();
  result.reserve(count / stride);
  for (size_t offset = 0; offset < count; offset += stride) {
    double rawDriverId = 0;
    double rawHasFrom = 0;
    smoothclip::Presentation from;
    smoothclip::Presentation target;
    if (!numberAt(runtime, array, offset, rawDriverId) ||
        !validDriverId(rawDriverId) ||
        !numberAt(runtime, array, offset + 1, rawHasFrom) ||
        (rawHasFrom != 0 && rawHasFrom != 1) ||
        !presentationV2At(runtime, array, offset + 2, from) ||
        !presentationV2At(runtime, array, offset + 14, target)) {
      return false;
    }
    result.push_back({
        static_cast<uint64_t>(rawDriverId),
        rawHasFrom == 1,
        from,
        target,
        {},
    });
  }
  return true;
}

bool keyframeGroupEntriesAt(
    jsi::Runtime &runtime,
    const jsi::Array &array,
    std::vector<smoothclip::GroupMotionEntry> &result) {
  const size_t count = array.size(runtime);
  if (count == 0) return false;
  result.clear();
  size_t cursor = 0;
  while (cursor < count) {
    constexpr size_t prefix = 27;
    if (count - cursor < prefix) return false;
    double rawDriverId = 0;
    double rawHasFrom = 0;
    double rawFrameCount = 0;
    smoothclip::Presentation from;
    smoothclip::Presentation target;
    if (!numberAt(runtime, array, cursor, rawDriverId) ||
        !validDriverId(rawDriverId) ||
        !numberAt(runtime, array, cursor + 1, rawHasFrom) ||
        (rawHasFrom != 0 && rawHasFrom != 1) ||
        !presentationV2At(runtime, array, cursor + 2, from) ||
        !presentationV2At(runtime, array, cursor + 14, target) ||
        !numberAt(runtime, array, cursor + 26, rawFrameCount) ||
        rawFrameCount < 2 || std::floor(rawFrameCount) != rawFrameCount) {
      return false;
    }
    const size_t frameCount = static_cast<size_t>(rawFrameCount);
    if (frameCount > (count - cursor - prefix) / 13) return false;
    std::vector<smoothclip::Keyframe> keyframes;
    keyframes.reserve(frameCount);
    double previousOffset = -1;
    const size_t framesOffset = cursor + prefix;
    for (size_t frameIndex = 0; frameIndex < frameCount; frameIndex += 1) {
      const size_t frameOffset = framesOffset + frameIndex * 13;
      double offset = 0;
      smoothclip::Presentation presentation;
      if (!numberAt(runtime, array, frameOffset, offset) || offset < 0 ||
          offset > 1 || offset <= previousOffset ||
          !presentationV2At(
              runtime, array, frameOffset + 1, presentation)) {
        return false;
      }
      previousOffset = offset;
      keyframes.push_back({offset, presentation});
    }
    if (keyframes.front().offset != 0 || keyframes.back().offset != 1) {
      return false;
    }
    result.push_back({
        static_cast<uint64_t>(rawDriverId),
        rawHasFrom == 1,
        from,
        target,
        std::move(keyframes),
    });
    cursor = framesOffset + frameCount * 13;
  }
  return !result.empty();
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

jsi::Array presentationArrayV2(
    jsi::Runtime &runtime,
    smoothclip::Presentation presentation,
    bool includeHandled = false,
    bool handled = true) {
  const size_t offset = includeHandled ? 1 : 0;
  jsi::Array result(runtime, offset + 12);
  if (includeHandled) result.setValueAtIndex(runtime, 0, handled ? 1.0 : 0.0);
  writePresentationV2(runtime, result, offset, presentation);
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
  smoothclip::setGroupCompletionCallback(
      this,
      [this](
          uint64_t controllerId,
          int32_t groupId,
          bool finished,
          std::vector<uint64_t> driverIds) {
        std::vector<double> jsDriverIds;
        jsDriverIds.reserve(driverIds.size());
        for (const uint64_t driverId : driverIds) {
          jsDriverIds.push_back(static_cast<double>(driverId));
        }
        emitOnClipGroupAnimationComplete(
            SmoothClipGroupAnimationCompletion{
                static_cast<double>(controllerId),
                groupId,
                finished,
                std::move(jsDriverIds),
            });
      });
}

SmoothClipTurboModule::~SmoothClipTurboModule() {
  smoothclip::clearCompletionCallback(this);
  smoothclip::clearGroupCompletionCallback(this);
}

int32_t SmoothClipTurboModule::getPresentationProtocolVersion(jsi::Runtime &) {
  return 2;
}

bool SmoothClipTurboModule::supportsAutonomousComplexPathAnimation(
    jsi::Runtime &) {
  return false;
}

jsi::Array SmoothClipTurboModule::beginGroupInteractionV2(
    jsi::Runtime &runtime,
    jsi::Array driverIds) {
  std::vector<uint64_t> parsed;
  if (!driverIdsAt(runtime, driverIds, parsed)) {
    return jsi::Array(runtime, 0);
  }
  return snapshotArrayV2(
      runtime, smoothclip::beginGroupInteraction(parsed));
}

jsi::Array SmoothClipTurboModule::snapshotGroupV2(
    jsi::Runtime &runtime,
    jsi::Array driverIds) {
  std::vector<uint64_t> parsed;
  if (!driverIdsAt(runtime, driverIds, parsed)) {
    return jsi::Array(runtime, 0);
  }
  return snapshotArrayV2(runtime, smoothclip::snapshotGroup(parsed));
}

bool SmoothClipTurboModule::setClipPresentationBatchV2(
    jsi::Runtime &runtime,
    jsi::Array entries) {
  constexpr size_t stride = 13;
  const size_t count = entries.size(runtime);
  if (count % stride != 0) return false;
  std::vector<smoothclip::BatchEntry> parsed;
  parsed.reserve(count / stride);
  for (size_t offset = 0; offset < count; offset += stride) {
    double driverId = 0;
    smoothclip::Presentation presentation;
    if (!numberAt(runtime, entries, offset, driverId) ||
        !validDriverId(driverId) ||
        !presentationV2At(runtime, entries, offset + 1, presentation)) {
      return false;
    }
    parsed.push_back(
        {static_cast<uint64_t>(driverId), presentation});
  }
  return smoothclip::setPresentationBatch(parsed);
}

int32_t SmoothClipTurboModule::animateTimingGroupV2(
    jsi::Runtime &runtime,
    double controllerId,
    jsi::Array entries,
    double durationMs,
    double controlPoint1X,
    double controlPoint1Y,
    double controlPoint2X,
    double controlPoint2Y,
    int32_t reduceMotion,
    int32_t suspensionPolicy) {
  std::vector<smoothclip::GroupMotionEntry> parsed;
  if (!validDriverId(controllerId) ||
      !fixedGroupEntriesAt(runtime, entries, parsed) ||
      !std::isfinite(durationMs) || !std::isfinite(controlPoint1X) ||
      !std::isfinite(controlPoint1Y) || !std::isfinite(controlPoint2X) ||
      !std::isfinite(controlPoint2Y) ||
      !validSuspensionPolicy(suspensionPolicy)) {
    return 0;
  }
  return smoothclip::animateTimingGroup(
      static_cast<uint64_t>(controllerId),
      std::move(parsed),
      {durationMs,
       controlPoint1X,
       controlPoint1Y,
       controlPoint2X,
       controlPoint2Y,
       reduceMotion},
      static_cast<smoothclip::GroupSuspensionPolicy>(suspensionPolicy));
}

int32_t SmoothClipTurboModule::animateSpringGroupV2(
    jsi::Runtime &runtime,
    double controllerId,
    jsi::Array entries,
    double mass,
    double stiffness,
    double damping,
    double initialVelocity,
    bool inheritVelocity,
    int32_t reduceMotion,
    int32_t suspensionPolicy) {
  std::vector<smoothclip::GroupMotionEntry> parsed;
  if (!validDriverId(controllerId) ||
      !fixedGroupEntriesAt(runtime, entries, parsed) ||
      !std::isfinite(mass) || !std::isfinite(stiffness) ||
      !std::isfinite(damping) || !std::isfinite(initialVelocity) ||
      mass <= 0 || stiffness <= 0 || damping < 0 ||
      !validSuspensionPolicy(suspensionPolicy)) {
    return 0;
  }
  return smoothclip::animateSpringGroup(
      static_cast<uint64_t>(controllerId),
      std::move(parsed),
      {mass,
       stiffness,
       damping,
       initialVelocity,
       inheritVelocity,
       reduceMotion},
      static_cast<smoothclip::GroupSuspensionPolicy>(suspensionPolicy));
}

int32_t SmoothClipTurboModule::animateKeyframesGroupV2(
    jsi::Runtime &runtime,
    double controllerId,
    jsi::Array entries,
    double durationMs,
    int32_t reduceMotion,
    int32_t suspensionPolicy) {
  std::vector<smoothclip::GroupMotionEntry> parsed;
  if (!validDriverId(controllerId) ||
      !keyframeGroupEntriesAt(runtime, entries, parsed) ||
      !std::isfinite(durationMs) ||
      !validSuspensionPolicy(suspensionPolicy)) {
    return 0;
  }
  return smoothclip::animateKeyframesGroup(
      static_cast<uint64_t>(controllerId),
      std::move(parsed),
      durationMs,
      reduceMotion,
      static_cast<smoothclip::GroupSuspensionPolicy>(suspensionPolicy));
}

jsi::Array SmoothClipTurboModule::cancelAnimationGroupV2(
    jsi::Runtime &runtime,
    int32_t groupId,
    int32_t behavior) {
  if (groupId <= 0 ||
      (behavior != static_cast<int32_t>(
                       smoothclip::GroupCancelBehavior::Freeze) &&
       behavior != static_cast<int32_t>(
                       smoothclip::GroupCancelBehavior::Finish))) {
    return jsi::Array(runtime, 0);
  }
  return snapshotArrayV2(
      runtime,
      smoothclip::cancelAnimationGroup(
          groupId,
          static_cast<smoothclip::GroupCancelBehavior>(behavior)));
}

void SmoothClipTurboModule::setClipPresentationV2(
    jsi::Runtime &,
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
    bool overridePendingAnimation) {
  const smoothclip::Presentation presentation = presentationV2(
      x, y, width, height, topLeftRadius, topRightRadius,
      bottomRightRadius, bottomLeftRadius, curveCode,
      contentTranslateX, contentTranslateY, contentScale);
  if (validDriverId(driverId) && finitePresentationV2(presentation)) {
    smoothclip::setPresentation(
        static_cast<uint64_t>(driverId), presentation, takeOwnership,
        overridePendingAnimation);
  }
}

jsi::Array SmoothClipTurboModule::beginInteractionV2(
    jsi::Runtime &runtime,
    double driverId) {
  if (!validDriverId(driverId)) {
    return presentationArrayV2(
        runtime, presentationV2(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1));
  }
  return presentationArrayV2(
      runtime,
      smoothclip::beginInteraction(static_cast<uint64_t>(driverId)));
}

jsi::Array SmoothClipTurboModule::snapshotCurrentV2(
    jsi::Runtime &runtime,
    double driverId) {
  if (!validDriverId(driverId)) {
    return presentationArrayV2(
        runtime, presentationV2(NAN, NAN, NAN, NAN, NAN, NAN, NAN, NAN,
                                0, NAN, NAN, NAN));
  }
  return presentationArrayV2(
      runtime,
      smoothclip::snapshotCurrent(static_cast<uint64_t>(driverId)));
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
    bool takeOwnership,
    bool overridePendingAnimation) {
  const smoothclip::Presentation presentation{
      {x, y, width, height, radius}, contentTranslateX, contentTranslateY};
  if (validDriverId(driverId) && finitePresentation(presentation)) {
    smoothclip::setPresentation(
        static_cast<uint64_t>(driverId), presentation, takeOwnership,
        overridePendingAnimation);
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
      animation,
      smoothclip::AnimationValidationMode::LegacyV1);
}

int32_t SmoothClipTurboModule::animateTimingV2(
    jsi::Runtime &,
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
    int32_t reduceMotion) {
  const smoothclip::Presentation startPresentation = presentationV2(
      startX, startY, startWidth, startHeight,
      startTopLeftRadius, startTopRightRadius,
      startBottomRightRadius, startBottomLeftRadius, startCurveCode,
      startContentTranslateX, startContentTranslateY, startContentScale);
  const smoothclip::Presentation presentation = presentationV2(
      x, y, width, height, topLeftRadius, topRightRadius,
      bottomRightRadius, bottomLeftRadius, curveCode,
      contentTranslateX, contentTranslateY, contentScale);
  const smoothclip::TimingAnimation animation{
      durationMs, controlPoint1X, controlPoint1Y,
      controlPoint2X, controlPoint2Y, reduceMotion};
  if (!validDriverId(driverId) ||
      !finitePresentationV2(startPresentation) ||
      !finitePresentationV2(presentation) ||
      !std::isfinite(durationMs) || !std::isfinite(controlPoint1X) ||
      !std::isfinite(controlPoint1Y) || !std::isfinite(controlPoint2X) ||
      !std::isfinite(controlPoint2Y)) {
    return 0;
  }
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
      !std::isfinite(damping) || !std::isfinite(initialVelocity)) return 0;

  return smoothclip::animateSpring(
      static_cast<uint64_t>(driverId),
      {hasInteractiveStart, startPresentation},
      presentation,
      animation,
      smoothclip::AnimationValidationMode::LegacyV1);
}

int32_t SmoothClipTurboModule::animateSpringV2(
    jsi::Runtime &,
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
    int32_t reduceMotion) {
  const smoothclip::Presentation startPresentation = presentationV2(
      startX, startY, startWidth, startHeight,
      startTopLeftRadius, startTopRightRadius,
      startBottomRightRadius, startBottomLeftRadius, startCurveCode,
      startContentTranslateX, startContentTranslateY, startContentScale);
  const smoothclip::Presentation presentation = presentationV2(
      x, y, width, height, topLeftRadius, topRightRadius,
      bottomRightRadius, bottomLeftRadius, curveCode,
      contentTranslateX, contentTranslateY, contentScale);
  const smoothclip::SpringAnimation animation{
      mass, stiffness, damping, initialVelocity,
      inheritVelocity, reduceMotion};
  if (!validDriverId(driverId) ||
      !finitePresentationV2(startPresentation) ||
      !finitePresentationV2(presentation) ||
      !std::isfinite(mass) || !std::isfinite(stiffness) ||
      !std::isfinite(damping) || !std::isfinite(initialVelocity) ||
      mass <= 0 || stiffness <= 0 || damping < 0) {
    return 0;
  }
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
      reduceMotion,
      smoothclip::AnimationValidationMode::LegacyV1);
}

int32_t SmoothClipTurboModule::animateKeyframesV2(
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
    int32_t reduceMotion) {
  const smoothclip::Presentation startPresentation = presentationV2(
      startX, startY, startWidth, startHeight,
      startTopLeftRadius, startTopRightRadius,
      startBottomRightRadius, startBottomLeftRadius, startCurveCode,
      startContentTranslateX, startContentTranslateY, startContentScale);
  const smoothclip::Presentation presentation = presentationV2(
      x, y, width, height, topLeftRadius, topRightRadius,
      bottomRightRadius, bottomLeftRadius, curveCode,
      contentTranslateX, contentTranslateY, contentScale);
  const size_t frameValueCount = frames.size(runtime);
  if (!validDriverId(driverId) ||
      !finitePresentationV2(startPresentation) ||
      !finitePresentationV2(presentation) || !std::isfinite(durationMs) ||
      frameValueCount < 26 || frameValueCount % 13 != 0) {
    return 0;
  }

  std::vector<smoothclip::Keyframe> keyframes;
  keyframes.reserve(frameValueCount / 13);
  double previousOffset = -1;
  for (size_t index = 0; index < frameValueCount; index += 13) {
    const double offset = frames.getValueAtIndex(runtime, index).asNumber();
    const double rawFrameCurveCode =
        frames.getValueAtIndex(runtime, index + 9).asNumber();
    const int32_t frameCurveCode =
        static_cast<int32_t>(rawFrameCurveCode);
    const smoothclip::Presentation frame = presentationV2(
        frames.getValueAtIndex(runtime, index + 1).asNumber(),
        frames.getValueAtIndex(runtime, index + 2).asNumber(),
        frames.getValueAtIndex(runtime, index + 3).asNumber(),
        frames.getValueAtIndex(runtime, index + 4).asNumber(),
        frames.getValueAtIndex(runtime, index + 5).asNumber(),
        frames.getValueAtIndex(runtime, index + 6).asNumber(),
        frames.getValueAtIndex(runtime, index + 7).asNumber(),
        frames.getValueAtIndex(runtime, index + 8).asNumber(),
        frameCurveCode,
        frames.getValueAtIndex(runtime, index + 10).asNumber(),
        frames.getValueAtIndex(runtime, index + 11).asNumber(),
        frames.getValueAtIndex(runtime, index + 12).asNumber());
    if (!std::isfinite(rawFrameCurveCode) ||
        rawFrameCurveCode != frameCurveCode ||
        !std::isfinite(offset) || offset < 0 || offset > 1 ||
        offset <= previousOffset || !finitePresentationV2(frame)) {
      return 0;
    }
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

int32_t SmoothClipTurboModule::animateTimingFromV2(
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
    int32_t reduceMotion) {
  return animateTimingV2(
      runtime, driverId, true,
      startX, startY, startWidth, startHeight,
      startTopLeftRadius, startTopRightRadius,
      startBottomRightRadius, startBottomLeftRadius, startCurveCode,
      startContentTranslateX, startContentTranslateY, startContentScale,
      x, y, width, height,
      topLeftRadius, topRightRadius, bottomRightRadius, bottomLeftRadius,
      curveCode, contentTranslateX, contentTranslateY, contentScale,
      durationMs, controlPoint1X, controlPoint1Y,
      controlPoint2X, controlPoint2Y, reduceMotion);
}

int32_t SmoothClipTurboModule::animateSpringFromV2(
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
    int32_t reduceMotion) {
  return animateSpringV2(
      runtime, driverId, true,
      startX, startY, startWidth, startHeight,
      startTopLeftRadius, startTopRightRadius,
      startBottomRightRadius, startBottomLeftRadius, startCurveCode,
      startContentTranslateX, startContentTranslateY, startContentScale,
      x, y, width, height,
      topLeftRadius, topRightRadius, bottomRightRadius, bottomLeftRadius,
      curveCode, contentTranslateX, contentTranslateY, contentScale,
      mass, stiffness, damping, initialVelocity, inheritVelocity,
      reduceMotion);
}

int32_t SmoothClipTurboModule::animateKeyframesFromV2(
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
    int32_t reduceMotion) {
  return animateKeyframesV2(
      runtime, driverId, true,
      startX, startY, startWidth, startHeight,
      startTopLeftRadius, startTopRightRadius,
      startBottomRightRadius, startBottomLeftRadius, startCurveCode,
      startContentTranslateX, startContentTranslateY, startContentScale,
      x, y, width, height,
      topLeftRadius, topRightRadius, bottomRightRadius, bottomLeftRadius,
      curveCode, contentTranslateX, contentTranslateY, contentScale,
      durationMs, std::move(frames), reduceMotion);
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

jsi::Array SmoothClipTurboModule::cancelAnimationV2(
    jsi::Runtime &runtime,
    double driverId,
    int32_t animationId,
    int32_t behavior) {
  if (!validDriverId(driverId)) {
    return presentationArrayV2(
        runtime,
        presentationV2(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1),
        true,
        false);
  }
  const smoothclip::CancelResult result = smoothclip::cancelAnimation(
      static_cast<uint64_t>(driverId), animationId, behavior == 1);
  return presentationArrayV2(
      runtime, result.presentation, true, result.handled);
}

void SmoothClipTurboModule::destroyDriver(jsi::Runtime &, double driverId) {
  if (validDriverId(driverId)) {
    smoothclip::destroyDriver(static_cast<uint64_t>(driverId));
  }
}

} // namespace facebook::react
