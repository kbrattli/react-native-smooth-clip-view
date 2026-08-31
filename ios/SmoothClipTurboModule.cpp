#include "SmoothClipTurboModule.h"

#include "SmoothClipAnimationCurve.h"
#include "SmoothClipRegistry.h"
#include "SmoothClipRegistrySnapshot.h"

#include <cmath>
#include <utility>

namespace facebook::react {
namespace {

constexpr size_t kPresentationStride = 21;
constexpr size_t kSnapshotStride = kPresentationStride + 1;
constexpr size_t kKeyframeStride = kPresentationStride + 1;
constexpr size_t kMotionEntryStride = kPresentationStride * 2 + 2;

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

smoothclip::Presentation makePresentation(
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
    bool shadowEnabled = false,
    double shadowRed = 0,
    double shadowGreen = 0,
    double shadowBlue = 0,
    double shadowAlpha = 1,
    double shadowOffsetX = 0,
    double shadowOffsetY = 0,
    double shadowBlurRadius = 0,
    double shadowSpreadDistance = 0) {
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
  return {
      geometry,
      contentTranslateX,
      contentTranslateY,
      contentScale,
      {shadowEnabled, shadowRed, shadowGreen, shadowBlue, shadowAlpha,
       shadowOffsetX, shadowOffsetY, shadowBlurRadius, shadowSpreadDistance}};
}

bool finitePresentation(const smoothclip::Presentation &presentation) {
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
      presentation.contentScale > 0 &&
      std::isfinite(presentation.shadow.red) &&
      std::isfinite(presentation.shadow.green) &&
      std::isfinite(presentation.shadow.blue) &&
      std::isfinite(presentation.shadow.alpha) &&
      std::isfinite(presentation.shadow.offsetX) &&
      std::isfinite(presentation.shadow.offsetY) &&
      std::isfinite(presentation.shadow.blurRadius) &&
      std::isfinite(presentation.shadow.spreadDistance) &&
      presentation.shadow.red >= 0 && presentation.shadow.red <= 1 &&
      presentation.shadow.green >= 0 && presentation.shadow.green <= 1 &&
      presentation.shadow.blue >= 0 && presentation.shadow.blue <= 1 &&
      presentation.shadow.alpha >= 0 && presentation.shadow.alpha <= 1 &&
      presentation.shadow.blurRadius >= 0;
}

bool presentationAt(
    jsi::Runtime &runtime,
    const jsi::Array &array,
    size_t offset,
    smoothclip::Presentation &result) {
  double values[kPresentationStride];
  for (size_t index = 0; index < kPresentationStride; index += 1) {
    if (!numberAt(runtime, array, offset + index, values[index])) {
      return false;
    }
  }
  const int32_t curveCode = static_cast<int32_t>(values[8]);
  if (values[8] != curveCode || !validCurveCode(curveCode) ||
      (values[12] != 0 && values[12] != 1)) return false;
  result = makePresentation(
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
      values[11],
      values[12] == 1,
      values[13], values[14], values[15], values[16],
      values[17], values[18], values[19], values[20]);
  return finitePresentation(result);
}

void writePresentation(
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
  result.setValueAtIndex(runtime, offset + 12, presentation.shadow.enabled ? 1.0 : 0.0);
  result.setValueAtIndex(runtime, offset + 13, presentation.shadow.red);
  result.setValueAtIndex(runtime, offset + 14, presentation.shadow.green);
  result.setValueAtIndex(runtime, offset + 15, presentation.shadow.blue);
  result.setValueAtIndex(runtime, offset + 16, presentation.shadow.alpha);
  result.setValueAtIndex(runtime, offset + 17, presentation.shadow.offsetX);
  result.setValueAtIndex(runtime, offset + 18, presentation.shadow.offsetY);
  result.setValueAtIndex(runtime, offset + 19, presentation.shadow.blurRadius);
  result.setValueAtIndex(runtime, offset + 20, presentation.shadow.spreadDistance);
}

jsi::Array snapshotArray(
    jsi::Runtime &runtime,
    const std::vector<smoothclip::DriverSnapshot> &snapshots) {
  jsi::Array result(runtime, snapshots.size() * kSnapshotStride);
  for (size_t index = 0; index < snapshots.size(); index += 1) {
    const size_t offset = index * kSnapshotStride;
    result.setValueAtIndex(
        runtime, offset, snapshots[index].ready ? 1.0 : 0.0);
    writePresentation(
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
  constexpr size_t stride = kMotionEntryStride;
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
        !presentationAt(runtime, array, offset + 2, from) ||
        !presentationAt(
            runtime, array, offset + 2 + kPresentationStride, target)) {
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
    constexpr size_t prefix = kMotionEntryStride + 1;
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
        !presentationAt(runtime, array, cursor + 2, from) ||
        !presentationAt(
            runtime, array, cursor + 2 + kPresentationStride, target) ||
        !numberAt(
            runtime, array, cursor + kMotionEntryStride, rawFrameCount) ||
        rawFrameCount < 2 || std::floor(rawFrameCount) != rawFrameCount) {
      return false;
    }
    const size_t frameCount = static_cast<size_t>(rawFrameCount);
    if (frameCount > (count - cursor - prefix) / kKeyframeStride) return false;
    std::vector<smoothclip::Keyframe> keyframes;
    keyframes.reserve(frameCount);
    double previousOffset = -1;
    const size_t framesOffset = cursor + prefix;
    for (size_t frameIndex = 0; frameIndex < frameCount; frameIndex += 1) {
      const size_t frameOffset = framesOffset + frameIndex * kKeyframeStride;
      double offset = 0;
      smoothclip::Presentation presentation;
      if (!numberAt(runtime, array, frameOffset, offset) || offset < 0 ||
          offset > 1 || offset <= previousOffset ||
          !presentationAt(
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
    cursor = framesOffset + frameCount * kKeyframeStride;
  }
  return !result.empty();
}

jsi::Array presentationArray(
    jsi::Runtime &runtime,
    smoothclip::Presentation presentation,
    bool includeHandled = false,
    bool handled = true) {
  const size_t offset = includeHandled ? 1 : 0;
  jsi::Array result(runtime, offset + kPresentationStride);
  if (includeHandled) result.setValueAtIndex(runtime, 0, handled ? 1.0 : 0.0);
  writePresentation(runtime, result, offset, presentation);
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

bool SmoothClipTurboModule::supportsAutonomousComplexPathAnimation(
    jsi::Runtime &) {
  return false;
}

jsi::Array SmoothClipTurboModule::beginGroupInteraction(
    jsi::Runtime &runtime,
    jsi::Array driverIds) {
  std::vector<uint64_t> parsed;
  if (!driverIdsAt(runtime, driverIds, parsed)) {
    return jsi::Array(runtime, 0);
  }
  return snapshotArray(
      runtime, smoothclip::beginGroupInteraction(parsed));
}

jsi::Array SmoothClipTurboModule::snapshotGroup(
    jsi::Runtime &runtime,
    jsi::Array driverIds) {
  std::vector<uint64_t> parsed;
  if (!driverIdsAt(runtime, driverIds, parsed)) {
    return jsi::Array(runtime, 0);
  }
  return snapshotArray(runtime, smoothclip::snapshotGroup(parsed));
}

bool SmoothClipTurboModule::setClipPresentationBatch(
    jsi::Runtime &runtime,
    jsi::Array entries) {
  constexpr size_t stride = kSnapshotStride;
  const size_t count = entries.size(runtime);
  if (count % stride != 0) return false;
  std::vector<smoothclip::BatchEntry> parsed;
  parsed.reserve(count / stride);
  for (size_t offset = 0; offset < count; offset += stride) {
    double driverId = 0;
    smoothclip::Presentation presentation;
    if (!numberAt(runtime, entries, offset, driverId) ||
        !validDriverId(driverId) ||
        !presentationAt(runtime, entries, offset + 1, presentation)) {
      return false;
    }
    parsed.push_back(
        {static_cast<uint64_t>(driverId), presentation});
  }
  return smoothclip::setPresentationBatch(parsed);
}

int32_t SmoothClipTurboModule::animateTimingGroup(
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

int32_t SmoothClipTurboModule::animateSpringGroup(
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

int32_t SmoothClipTurboModule::animateKeyframesGroup(
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

jsi::Array SmoothClipTurboModule::cancelAnimationGroup(
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
  return snapshotArray(
      runtime,
      smoothclip::cancelAnimationGroup(
          groupId,
          static_cast<smoothclip::GroupCancelBehavior>(behavior)));
}

void SmoothClipTurboModule::setClipPresentation(
    jsi::Runtime &runtime,
    double driverId,
    jsi::Array values,
    bool takeOwnership,
    bool overridePendingAnimation) {
  smoothclip::Presentation presentation{};
  if (values.size(runtime) == kPresentationStride &&
      validDriverId(driverId) &&
      presentationAt(runtime, values, 0, presentation)) {
    smoothclip::setPresentation(
        static_cast<uint64_t>(driverId), presentation, takeOwnership,
        overridePendingAnimation);
  }
}

void SmoothClipTurboModule::setClipPresentationScalars(
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
    bool overridePendingAnimation,
    bool recordVelocity) {
  const smoothclip::Presentation parsed = makePresentation(
      x, y, width, height, topLeftRadius, topRightRadius,
      bottomRightRadius, bottomLeftRadius, curveCode,
      contentTranslateX, contentTranslateY, contentScale);
  if (!validDriverId(driverId) || !finitePresentation(parsed)) return;
  smoothclip::setScalars(
      static_cast<uint64_t>(driverId), parsed.clip,
      contentTranslateX, contentTranslateY, contentScale,
      overridePendingAnimation, recordVelocity);
}

jsi::Array SmoothClipTurboModule::beginInteraction(
    jsi::Runtime &runtime,
    double driverId) {
  if (!validDriverId(driverId)) {
    return presentationArray(
        runtime, makePresentation(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1));
  }
  return presentationArray(
      runtime,
      smoothclip::beginInteraction(static_cast<uint64_t>(driverId)));
}

jsi::Array SmoothClipTurboModule::snapshotCurrent(
    jsi::Runtime &runtime,
    double driverId) {
  if (!validDriverId(driverId)) {
    return presentationArray(
        runtime, makePresentation(NAN, NAN, NAN, NAN, NAN, NAN, NAN, NAN,
                                0, NAN, NAN, NAN));
  }
  return presentationArray(
      runtime,
      smoothclip::snapshotCurrent(static_cast<uint64_t>(driverId)));
}

int32_t SmoothClipTurboModule::animateTiming(
    jsi::Runtime &runtime,
    double driverId,
    jsi::Array start,
    jsi::Array target,
    double durationMs,
    double controlPoint1X,
    double controlPoint1Y,
    double controlPoint2X,
    double controlPoint2Y,
    int32_t reduceMotion) {
  const bool hasInteractiveStart = start.size(runtime) != 0;
  smoothclip::Presentation startPresentation{};
  smoothclip::Presentation presentation{};
  const smoothclip::TimingAnimation animation{
      durationMs, controlPoint1X, controlPoint1Y,
      controlPoint2X, controlPoint2Y, reduceMotion};
  if (!validDriverId(driverId) ||
      (hasInteractiveStart &&
       (start.size(runtime) != kPresentationStride ||
        !presentationAt(runtime, start, 0, startPresentation))) ||
      target.size(runtime) != kPresentationStride ||
      !presentationAt(runtime, target, 0, presentation) ||
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
    jsi::Runtime &runtime,
    double driverId,
    jsi::Array start,
    jsi::Array target,
    double mass,
    double stiffness,
    double damping,
    double initialVelocity,
    bool inheritVelocity,
    int32_t reduceMotion) {
  const bool hasInteractiveStart = start.size(runtime) != 0;
  smoothclip::Presentation startPresentation{};
  smoothclip::Presentation presentation{};
  const smoothclip::SpringAnimation animation{
      mass, stiffness, damping, initialVelocity,
      inheritVelocity, reduceMotion};
  if (!validDriverId(driverId) ||
      (hasInteractiveStart &&
       (start.size(runtime) != kPresentationStride ||
        !presentationAt(runtime, start, 0, startPresentation))) ||
      target.size(runtime) != kPresentationStride ||
      !presentationAt(runtime, target, 0, presentation) ||
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
    jsi::Array start,
    jsi::Array target,
    double durationMs,
    jsi::Array frames,
    int32_t reduceMotion) {
  const bool hasInteractiveStart = start.size(runtime) != 0;
  smoothclip::Presentation startPresentation{};
  smoothclip::Presentation presentation{};
  const size_t frameValueCount = frames.size(runtime);
  if (!validDriverId(driverId) ||
      (hasInteractiveStart &&
       (start.size(runtime) != kPresentationStride ||
        !presentationAt(runtime, start, 0, startPresentation))) ||
      target.size(runtime) != kPresentationStride ||
      !presentationAt(runtime, target, 0, presentation) ||
      !std::isfinite(durationMs) ||
      frameValueCount < kKeyframeStride * 2 ||
      frameValueCount % kKeyframeStride != 0) {
    return 0;
  }

  std::vector<smoothclip::Keyframe> keyframes;
  keyframes.reserve(frameValueCount / kKeyframeStride);
  double previousOffset = -1;
  for (size_t index = 0; index < frameValueCount; index += kKeyframeStride) {
    double offset;
    smoothclip::Presentation frame{};
    if (!numberAt(runtime, frames, index, offset) ||
        offset < 0 || offset > 1 || offset <= previousOffset ||
        !presentationAt(runtime, frames, index + 1, frame)) {
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
        runtime,
        makePresentation(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1),
        true,
        false);
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
