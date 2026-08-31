#include "SmoothClipAndroid.h"

#include <ReactCommon/BindingsInstallerHolder.h>
#include <ReactCommon/CallInvoker.h>
#include <fbjni/fbjni.h>
#include <jsi/jsi.h>

#include <algorithm>
#include <cmath>
#include <limits>
#include <memory>
#include <unordered_map>
#include <utility>
#include <vector>

using namespace facebook;
using facebook::jsi::Array;
using facebook::jsi::Function;
using facebook::jsi::Object;
using facebook::jsi::PropNameID;
using facebook::jsi::Runtime;
using facebook::jsi::Value;
using facebook::react::BindingsInstallerHolder;
using facebook::react::CallInvoker;

namespace smoothclip {
namespace {

constexpr double kMaxSafeJavaScriptInteger = 9007199254740991.0;
constexpr size_t kPresentationStride = 21;
constexpr size_t kSnapshotStride = kPresentationStride + 1;
constexpr size_t kKeyframeStride = kPresentationStride + 1;
constexpr size_t kMotionEntryStride = kPresentationStride * 2 + 2;

bool validDriverId(double value) {
  return std::isfinite(value) && value > 0 &&
      value <= kMaxSafeJavaScriptInteger && std::floor(value) == value;
}

bool validCurve(double value) {
  return std::isfinite(value) && std::floor(value) == value &&
      (value == static_cast<double>(ClipCurve::Circular) ||
       value == static_cast<double>(ClipCurve::Continuous));
}

bool validRadiusOverride(double value) {
  return std::isfinite(value) || std::isnan(value);
}

bool finiteBasePresentation(const Presentation &presentation) {
  return std::isfinite(presentation.clip.x) &&
      std::isfinite(presentation.clip.y) &&
      std::isfinite(presentation.clip.width) &&
      std::isfinite(presentation.clip.height) &&
      std::isfinite(presentation.clip.radius) &&
      validRadiusOverride(presentation.clip.topLeftRadius) &&
      validRadiusOverride(presentation.clip.topRightRadius) &&
      validRadiusOverride(presentation.clip.bottomRightRadius) &&
      validRadiusOverride(presentation.clip.bottomLeftRadius) &&
      (presentation.clip.curve == ClipCurve::Circular ||
       presentation.clip.curve == ClipCurve::Continuous) &&
      std::isfinite(presentation.contentTranslateX) &&
      std::isfinite(presentation.contentTranslateY) &&
      std::isfinite(presentation.contentScale) &&
      presentation.contentScale > 0;
}

bool finitePresentation(const Presentation &presentation) {
  return finiteBasePresentation(presentation) &&
      std::isfinite(presentation.clip.topLeftRadius) &&
      std::isfinite(presentation.clip.topRightRadius) &&
      std::isfinite(presentation.clip.bottomRightRadius) &&
      std::isfinite(presentation.clip.bottomLeftRadius) &&
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

bool boolArg(const Value *args, size_t count, size_t index) {
  return index < count && args[index].isBool() && args[index].getBool();
}

bool numberAt(
    Runtime &runtime,
    const Array &values,
    size_t index,
    double &result) {
  if (index >= values.size(runtime)) return false;
  const Value value = values.getValueAtIndex(runtime, index);
  if (!value.isNumber()) return false;
  result = value.asNumber();
  return std::isfinite(result);
}

// Optional trailing start stamp (Reanimated-rule milliseconds captured in the
// issuing worklet), converted to the registry's CLOCK_MONOTONIC seconds. A
// missing or non-numeric argument — and the JS side's deliberate NaN fallback
// when the worklet globals are absent — resolves to NaN, which
// resolveStartStamp() treats as "no hint": nowSeconds() plus the min() anchor,
// exactly the pre-hint behavior.
double startStampArg(const Value *args, size_t count, size_t index) {
  return index < count && args[index].isNumber()
      ? args[index].asNumber() / 1000.0
      : std::numeric_limits<double>::quiet_NaN();
}

bool presentationAt(
    Runtime &runtime,
    const Array &values,
    size_t offset,
    Presentation &result) {
  const size_t length = values.size(runtime);
  if (offset > length || length - offset < kPresentationStride) {
    return false;
  }
  double packet[kPresentationStride];
  for (size_t index = 0; index < kPresentationStride; index += 1) {
    const Value value = values.getValueAtIndex(runtime, offset + index);
    if (!value.isNumber()) return false;
    packet[index] = value.asNumber();
  }
  const double curveCode = packet[8];
  if (!validCurve(curveCode) ||
      (packet[12] != 0.0 && packet[12] != 1.0)) {
    return false;
  }
  Geometry geometry{
      packet[0], packet[1], packet[2], packet[3],
      0.0};
  geometry.topLeftRadius = packet[4];
  geometry.topRightRadius = packet[5];
  geometry.bottomRightRadius = packet[6];
  geometry.bottomLeftRadius = packet[7];
  geometry.curve = curveCode == static_cast<double>(ClipCurve::Continuous)
      ? ClipCurve::Continuous
      : ClipCurve::Circular;
  if (geometry.topLeftRadius == geometry.topRightRadius &&
      geometry.topLeftRadius == geometry.bottomRightRadius &&
      geometry.topLeftRadius == geometry.bottomLeftRadius) {
    geometry.radius = geometry.topLeftRadius;
  }
  result = Presentation{
      geometry,
      packet[9], packet[10], packet[11],
      Shadow{
          packet[12] == 1.0,
          packet[13], packet[14], packet[15], packet[16],
          packet[17], packet[18], packet[19], packet[20]}};
  return finitePresentation(result);
}

void appendPresentation(
    Runtime &runtime,
    Array &result,
    size_t &offset,
    const Presentation &presentation) {
  result.setValueAtIndex(runtime, offset++, presentation.clip.x);
  result.setValueAtIndex(runtime, offset++, presentation.clip.y);
  result.setValueAtIndex(runtime, offset++, presentation.clip.width);
  result.setValueAtIndex(runtime, offset++, presentation.clip.height);
  result.setValueAtIndex(runtime, offset++, SmoothClipResolvedRadius(
      presentation.clip.topLeftRadius, presentation.clip.radius));
  result.setValueAtIndex(runtime, offset++, SmoothClipResolvedRadius(
      presentation.clip.topRightRadius, presentation.clip.radius));
  result.setValueAtIndex(runtime, offset++, SmoothClipResolvedRadius(
      presentation.clip.bottomRightRadius, presentation.clip.radius));
  result.setValueAtIndex(runtime, offset++, SmoothClipResolvedRadius(
      presentation.clip.bottomLeftRadius, presentation.clip.radius));
  result.setValueAtIndex(
      runtime, offset++, static_cast<double>(presentation.clip.curve));
  result.setValueAtIndex(runtime, offset++, presentation.contentTranslateX);
  result.setValueAtIndex(runtime, offset++, presentation.contentTranslateY);
  result.setValueAtIndex(runtime, offset++, presentation.contentScale);
  result.setValueAtIndex(
      runtime, offset++, presentation.shadow.enabled ? 1.0 : 0.0);
  result.setValueAtIndex(runtime, offset++, presentation.shadow.red);
  result.setValueAtIndex(runtime, offset++, presentation.shadow.green);
  result.setValueAtIndex(runtime, offset++, presentation.shadow.blue);
  result.setValueAtIndex(runtime, offset++, presentation.shadow.alpha);
  result.setValueAtIndex(runtime, offset++, presentation.shadow.offsetX);
  result.setValueAtIndex(runtime, offset++, presentation.shadow.offsetY);
  result.setValueAtIndex(runtime, offset++, presentation.shadow.blurRadius);
  result.setValueAtIndex(runtime, offset++, presentation.shadow.spreadDistance);
}

Array presentationArray(Runtime &runtime, const Presentation &presentation) {
  Array result(runtime, kPresentationStride);
  size_t offset = 0;
  appendPresentation(runtime, result, offset, presentation);
  return result;
}

Array cancelResultArray(
    Runtime &runtime,
    bool handled,
    const Presentation &presentation) {
  Array result(runtime, kSnapshotStride);
  result.setValueAtIndex(runtime, 0, handled ? 1.0 : 0.0);
  size_t offset = 1;
  appendPresentation(runtime, result, offset, presentation);
  return result;
}

Array snapshotsArray(
    Runtime &runtime,
    const std::vector<DriverSnapshot> &snapshots) {
  Array result(runtime, snapshots.size() * kSnapshotStride);
  size_t offset = 0;
  for (const DriverSnapshot &snapshot : snapshots) {
    result.setValueAtIndex(runtime, offset++, snapshot.ready ? 1.0 : 0.0);
    const Presentation &presentation = snapshot.presentation;
    appendPresentation(runtime, result, offset, presentation);
  }
  return result;
}

bool validSuspensionPolicy(double value) {
  return value == static_cast<double>(GroupSuspensionPolicy::Pause) ||
      value == static_cast<double>(GroupSuspensionPolicy::Finish);
}

std::vector<uint64_t> driverIdsFromArray(Runtime &runtime, const Array &values) {
  std::vector<uint64_t> driverIds;
  const size_t length = values.size(runtime);
  driverIds.reserve(length);
  for (size_t index = 0; index < length; index += 1) {
    double value;
    if (!numberAt(runtime, values, index, value) || !validDriverId(value) ||
        std::find(driverIds.begin(), driverIds.end(),
                  static_cast<uint64_t>(value)) != driverIds.end()) {
      return {};
    }
    driverIds.push_back(static_cast<uint64_t>(value));
  }
  return driverIds;
}

bool parseGroupMotionEntries(
    Runtime &runtime,
    const Array &values,
    std::vector<GroupMotionEntry> &entries) {
  const size_t length = values.size(runtime);
  if (length < kMotionEntryStride || length % kMotionEntryStride != 0) {
    return false;
  }
  entries.reserve(length / kMotionEntryStride);
  for (size_t index = 0; index < length; index += kMotionEntryStride) {
    double driverId;
    double hasFromValue;
    Presentation from;
    Presentation target;
    if (!numberAt(runtime, values, index, driverId) ||
        !numberAt(runtime, values, index + 1, hasFromValue) ||
        !presentationAt(runtime, values, index + 2, from) ||
        !presentationAt(
            runtime, values, index + 2 + kPresentationStride, target) ||
        !validDriverId(driverId) ||
        (hasFromValue != 0.0 && hasFromValue != 1.0) ||
        !finitePresentation(from) || !finitePresentation(target)) {
      entries.clear();
      return false;
    }
    entries.push_back(
        {static_cast<uint64_t>(driverId), hasFromValue == 1.0, from, target, {}});
  }
  return true;
}

bool parseGroupKeyframeEntries(
    Runtime &runtime,
    const Array &values,
    std::vector<GroupMotionEntry> &entries) {
  const size_t length = values.size(runtime);
  size_t index = 0;
  while (index < length) {
    constexpr size_t prefix = kMotionEntryStride + 1;
    if (length - index < prefix) return false;
    double driverId;
    double hasFromValue;
    double frameCountValue;
    Presentation from;
    Presentation target;
    if (!numberAt(runtime, values, index, driverId) ||
        !numberAt(runtime, values, index + 1, hasFromValue) ||
        !numberAt(
            runtime, values, index + kMotionEntryStride, frameCountValue) ||
        !presentationAt(runtime, values, index + 2, from) ||
        !presentationAt(
            runtime, values, index + 2 + kPresentationStride, target) ||
        !validDriverId(driverId) ||
        (hasFromValue != 0.0 && hasFromValue != 1.0) ||
        !finitePresentation(from) || !finitePresentation(target) ||
        !std::isfinite(frameCountValue) || frameCountValue < 2 ||
        std::floor(frameCountValue) != frameCountValue) {
      return false;
    }
    const size_t frameCount = static_cast<size_t>(frameCountValue);
    index += prefix;
    if (frameCount > (length - index) / kKeyframeStride) return false;
    std::vector<Keyframe> keyframes;
    keyframes.reserve(frameCount);
    double previousOffset = -1;
    for (size_t frameIndex = 0; frameIndex < frameCount; frameIndex += 1) {
      double offset;
      Presentation presentation;
      if (!numberAt(runtime, values, index, offset) ||
          !presentationAt(runtime, values, index + 1, presentation) ||
          offset < 0 || offset > 1 || offset <= previousOffset ||
          !finitePresentation(presentation)) {
        return false;
      }
      previousOffset = offset;
      keyframes.push_back({offset, presentation});
      index += kKeyframeStride;
    }
    if (keyframes.front().offset != 0 || keyframes.back().offset != 1) {
      return false;
    }
    entries.push_back({
        static_cast<uint64_t>(driverId),
        hasFromValue == 1.0,
        from,
        target,
        std::move(keyframes)});
  }
  return !entries.empty();
}

struct BindingsState {
  Runtime *runtime = nullptr;
  std::shared_ptr<CallInvoker> callInvoker;
  std::unordered_map<int32_t, std::shared_ptr<Function>> listeners;
  std::unordered_map<int32_t, std::shared_ptr<Function>> groupListeners;
  int32_t nextListenerId = 0;
};

std::shared_ptr<BindingsState> &bindingsState() {
  static std::shared_ptr<BindingsState> state = std::make_shared<BindingsState>();
  return state;
}

void setHostFunction(
    Runtime &runtime,
    Object &target,
    const char *name,
    unsigned int paramCount,
    jsi::HostFunctionType &&function) {
  target.setProperty(
      runtime,
      name,
      Function::createFromHostFunction(
          runtime,
          PropNameID::forAscii(runtime, name),
          paramCount,
          std::move(function)));
}

} // namespace

void installBindings(
    Runtime &runtime,
    const std::shared_ptr<CallInvoker> &callInvoker) {
  auto state = bindingsState();
  // A reinstall means a new runtime (reload / new host). Listener functions
  // created on the previous runtime must never be called with — or destroyed
  // against — the new one; the TurboModule invalidate hook releases them
  // while their runtime is still alive, and this is the safety net.
  state->listeners.clear();
  state->groupListeners.clear();
  state->runtime = &runtime;
  state->callInvoker = callInvoker;

  setCompletionCallback(
      state.get(),
      [state](uint64_t driverId, int32_t animationId, bool finished) {
        auto invoker = state->callInvoker;
        if (!invoker) return;
        invoker->invokeAsync([state, driverId, animationId, finished]() {
          if (state->runtime == nullptr) return;
          Runtime &rt = *state->runtime;
          std::vector<std::shared_ptr<Function>> snapshot;
          snapshot.reserve(state->listeners.size());
          for (const auto &entry : state->listeners) {
            snapshot.push_back(entry.second);
          }
          for (const auto &listener : snapshot) {
            Object result(rt);
            result.setProperty(rt, "driverId", static_cast<double>(driverId));
            result.setProperty(rt, "animationId", animationId);
            result.setProperty(rt, "finished", finished);
            listener->call(rt, std::move(result));
          }
        });
      });

  setGroupCompletionCallback(
      state.get(),
      [state](
          uint64_t controllerId,
          int32_t groupId,
          bool finished,
          std::vector<uint64_t> driverIds) {
        auto invoker = state->callInvoker;
        if (!invoker) return;
        invoker->invokeAsync(
            [state, controllerId, groupId, finished,
             driverIds = std::move(driverIds)]() {
              if (state->runtime == nullptr) return;
              Runtime &rt = *state->runtime;
              std::vector<std::shared_ptr<Function>> snapshot;
              snapshot.reserve(state->groupListeners.size());
              for (const auto &entry : state->groupListeners) {
                snapshot.push_back(entry.second);
              }
              for (const auto &listener : snapshot) {
                Object result(rt);
                result.setProperty(
                    rt, "controllerId", static_cast<double>(controllerId));
                result.setProperty(rt, "groupId", groupId);
                result.setProperty(rt, "finished", finished);
                Array ids(rt, driverIds.size());
                for (size_t index = 0; index < driverIds.size(); index += 1) {
                  ids.setValueAtIndex(
                      rt, index, static_cast<double>(driverIds[index]));
                }
                result.setProperty(rt, "driverIds", std::move(ids));
                listener->call(rt, std::move(result));
              }
            });
      });

  Object bindings(runtime);

  setHostFunction(
      runtime, bindings, "supportsAutonomousComplexPathAnimation", 0,
      [](Runtime &, const Value &, const Value *, size_t) -> Value {
        // Static complex clipping is available. Autonomous complex-path
        // animation is deliberately gated off until physical-device sampling
        // proves the release tolerance and frame-time requirements.
        return Value(false);
      });

  setHostFunction(
      runtime, bindings, "beginGroupInteraction", 1,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 1 || !args[0].isObject() ||
            !args[0].getObject(rt).isArray(rt)) {
          return Array(rt, 0);
        }
        Array values = args[0].getObject(rt).getArray(rt);
        const std::vector<uint64_t> driverIds = driverIdsFromArray(rt, values);
        if (driverIds.empty()) return Array(rt, 0);
        return snapshotsArray(rt, beginGroupInteraction(driverIds));
      });

  setHostFunction(
      runtime, bindings, "snapshotGroup", 1,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 1 || !args[0].isObject() ||
            !args[0].getObject(rt).isArray(rt)) {
          return Array(rt, 0);
        }
        Array values = args[0].getObject(rt).getArray(rt);
        const std::vector<uint64_t> driverIds = driverIdsFromArray(rt, values);
        if (driverIds.empty()) return Array(rt, 0);
        return snapshotsArray(rt, snapshotGroup(driverIds));
      });

  setHostFunction(
      runtime, bindings, "setClipPresentationBatch", 1,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 1 || !args[0].isObject() ||
            !args[0].getObject(rt).isArray(rt)) {
          return Value(false);
        }
        Array values = args[0].getObject(rt).getArray(rt);
        const size_t length = values.size(rt);
        if (length < kSnapshotStride || length % kSnapshotStride != 0) {
          return Value(false);
        }
        std::vector<BatchEntry> entries;
        entries.reserve(length / kSnapshotStride);
        for (size_t index = 0; index < length; index += kSnapshotStride) {
          double driverId;
          Presentation presentation;
          if (!numberAt(rt, values, index, driverId) ||
              !presentationAt(rt, values, index + 1, presentation) ||
              !validDriverId(driverId) || !finitePresentation(presentation)) {
            return Value(false);
          }
          entries.push_back(
              {static_cast<uint64_t>(driverId), presentation});
        }
        return Value(setPresentationBatch(entries));
      });

  setHostFunction(
      runtime, bindings, "animateTimingGroup", 10,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 9 || !args[1].isObject() ||
            !args[1].getObject(rt).isArray(rt)) {
          return Value(0);
        }
        const double controllerId = args[0].asNumber();
        Array values = args[1].getObject(rt).getArray(rt);
        std::vector<GroupMotionEntry> entries;
        const TimingAnimation animation{
            args[2].asNumber(), args[3].asNumber(), args[4].asNumber(),
            args[5].asNumber(), args[6].asNumber(),
            static_cast<int32_t>(args[7].asNumber())};
        const double suspension = args[8].asNumber();
        if (!validDriverId(controllerId) ||
            !parseGroupMotionEntries(rt, values, entries) ||
            !std::isfinite(animation.durationMs) ||
            !std::isfinite(animation.controlPoint1X) ||
            !std::isfinite(animation.controlPoint1Y) ||
            !std::isfinite(animation.controlPoint2X) ||
            !std::isfinite(animation.controlPoint2Y) ||
            !validSuspensionPolicy(suspension)) {
          return Value(0);
        }
        return Value(animateTimingGroup(
            static_cast<uint64_t>(controllerId),
            std::move(entries),
            animation,
            static_cast<GroupSuspensionPolicy>(
                static_cast<int32_t>(suspension)),
            startStampArg(args, count, 9)));
      });

  setHostFunction(
      runtime, bindings, "animateSpringGroup", 10,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 9 || !args[1].isObject() ||
            !args[1].getObject(rt).isArray(rt)) {
          return Value(0);
        }
        const double controllerId = args[0].asNumber();
        Array values = args[1].getObject(rt).getArray(rt);
        std::vector<GroupMotionEntry> entries;
        const SpringAnimation animation{
            args[2].asNumber(), args[3].asNumber(), args[4].asNumber(),
            args[5].asNumber(), boolArg(args, count, 6),
            static_cast<int32_t>(args[7].asNumber())};
        const double suspension = args[8].asNumber();
        if (!validDriverId(controllerId) ||
            !parseGroupMotionEntries(rt, values, entries) ||
            !std::isfinite(animation.mass) ||
            !std::isfinite(animation.stiffness) ||
            !std::isfinite(animation.damping) ||
            !std::isfinite(animation.initialVelocity) || animation.mass <= 0 ||
            animation.stiffness <= 0 || animation.damping < 0 ||
            !validSuspensionPolicy(suspension)) {
          return Value(0);
        }
        return Value(animateSpringGroup(
            static_cast<uint64_t>(controllerId),
            std::move(entries),
            animation,
            static_cast<GroupSuspensionPolicy>(
                static_cast<int32_t>(suspension)),
            startStampArg(args, count, 9)));
      });

  setHostFunction(
      runtime, bindings, "animateKeyframesGroup", 6,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 5 || !args[1].isObject() ||
            !args[1].getObject(rt).isArray(rt)) {
          return Value(0);
        }
        const double controllerId = args[0].asNumber();
        Array values = args[1].getObject(rt).getArray(rt);
        std::vector<GroupMotionEntry> entries;
        const double durationMs = args[2].asNumber();
        const int32_t reduceMotion = static_cast<int32_t>(args[3].asNumber());
        const double suspension = args[4].asNumber();
        if (!validDriverId(controllerId) ||
            !parseGroupKeyframeEntries(rt, values, entries) ||
            !std::isfinite(durationMs) ||
            !validSuspensionPolicy(suspension)) {
          return Value(0);
        }
        return Value(animateKeyframesGroup(
            static_cast<uint64_t>(controllerId),
            std::move(entries),
            durationMs,
            reduceMotion,
            static_cast<GroupSuspensionPolicy>(
                static_cast<int32_t>(suspension)),
            startStampArg(args, count, 5)));
      });

  setHostFunction(
      runtime, bindings, "cancelAnimationGroup", 2,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 2 || !args[0].isNumber() || !args[1].isNumber()) {
          return Array(rt, 0);
        }
        const double groupId = args[0].asNumber();
        const double behavior = args[1].asNumber();
        if (!std::isfinite(groupId) || groupId <= 0 ||
            std::floor(groupId) != groupId ||
            (behavior != static_cast<double>(GroupCancelBehavior::Freeze) &&
             behavior != static_cast<double>(GroupCancelBehavior::Finish))) {
          return Array(rt, 0);
        }
        return snapshotsArray(
            rt,
            cancelAnimationGroup(
                static_cast<int32_t>(groupId),
                static_cast<GroupCancelBehavior>(
                    static_cast<int32_t>(behavior))));
      });

  setHostFunction(
      runtime, bindings, "setClipPresentation", 4,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 4 || !args[0].isNumber() || !args[1].isObject() ||
            !args[1].getObject(rt).isArray(rt)) {
          return Value::undefined();
        }
        const double driverId = args[0].asNumber();
        const Array values = args[1].getObject(rt).getArray(rt);
        Presentation presentation;
        if (values.size(rt) == kPresentationStride &&
            validDriverId(driverId) &&
            presentationAt(rt, values, 0, presentation)) {
          setPresentation(
              static_cast<uint64_t>(driverId), presentation,
              boolArg(args, count, 2), boolArg(args, count, 3), true);
        }
        return Value::undefined();
      });

  setHostFunction(
      runtime, bindings, "setClipPresentationScalars", 15,
      [](Runtime &, const Value &, const Value *args, size_t count) -> Value {
        if (count < 15) return Value::undefined();
        const double driverId = args[0].asNumber();
        Geometry geometry{
            args[1].asNumber(), args[2].asNumber(), args[3].asNumber(),
            args[4].asNumber(), 0};
        geometry.topLeftRadius = args[5].asNumber();
        geometry.topRightRadius = args[6].asNumber();
        geometry.bottomRightRadius = args[7].asNumber();
        geometry.bottomLeftRadius = args[8].asNumber();
        geometry.curve = static_cast<ClipCurve>(
            static_cast<int32_t>(args[9].asNumber()));
        if (geometry.topLeftRadius == geometry.topRightRadius &&
            geometry.topLeftRadius == geometry.bottomRightRadius &&
            geometry.topLeftRadius == geometry.bottomLeftRadius) {
          geometry.radius = geometry.topLeftRadius;
        }
        const Presentation parsed{
            geometry, args[10].asNumber(), args[11].asNumber(),
            args[12].asNumber()};
        if (validDriverId(driverId) && validCurve(args[9].asNumber()) &&
            finitePresentation(parsed)) {
          setScalars(
              static_cast<uint64_t>(driverId), geometry,
              parsed.contentTranslateX, parsed.contentTranslateY,
              parsed.contentScale, boolArg(args, count, 13),
              boolArg(args, count, 14));
        }
        return Value::undefined();
      });

  setHostFunction(
      runtime, bindings, "beginInteraction", 1,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 1 || !validDriverId(args[0].asNumber())) {
          return presentationArray(rt, {{0, 0, 0, 0, 0}, 0, 0});
        }
        return presentationArray(
            rt, beginInteraction(static_cast<uint64_t>(args[0].asNumber())));
      });

  setHostFunction(
      runtime, bindings, "snapshotCurrent", 1,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 1 || !validDriverId(args[0].asNumber())) {
          return presentationArray(rt, {{0, 0, 0, 0, 0}, 0, 0});
        }
        return presentationArray(
            rt,
            snapshotCurrentAndroid(
                static_cast<uint64_t>(args[0].asNumber())));
      });

  setHostFunction(
      runtime, bindings, "animateTiming", 10,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 9 || !args[0].isNumber() || !args[1].isObject() ||
            !args[1].getObject(rt).isArray(rt) || !args[2].isObject() ||
            !args[2].getObject(rt).isArray(rt)) {
          return Value(0);
        }
        const double driverId = args[0].asNumber();
        const Array startValues = args[1].getObject(rt).getArray(rt);
        const Array targetValues = args[2].getObject(rt).getArray(rt);
        const bool hasInteractiveStart = startValues.size(rt) != 0;
        Presentation start{};
        Presentation target;
        const TimingAnimation animation{
            args[3].asNumber(), args[4].asNumber(), args[5].asNumber(),
            args[6].asNumber(), args[7].asNumber(),
            static_cast<int32_t>(args[8].asNumber())};
        if (!validDriverId(driverId) ||
            (hasInteractiveStart &&
             (startValues.size(rt) != kPresentationStride ||
              !presentationAt(rt, startValues, 0, start))) ||
            targetValues.size(rt) != kPresentationStride ||
            !presentationAt(rt, targetValues, 0, target) ||
            !std::isfinite(animation.durationMs)) {
          return Value(0);
        }
        return Value(animateTiming(
            static_cast<uint64_t>(driverId),
            {hasInteractiveStart, start, startStampArg(args, count, 9)},
            target,
            animation));
      });

  setHostFunction(
      runtime, bindings, "animateSpring", 10,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 9 || !args[0].isNumber() || !args[1].isObject() ||
            !args[1].getObject(rt).isArray(rt) || !args[2].isObject() ||
            !args[2].getObject(rt).isArray(rt)) {
          return Value(0);
        }
        const double driverId = args[0].asNumber();
        const Array startValues = args[1].getObject(rt).getArray(rt);
        const Array targetValues = args[2].getObject(rt).getArray(rt);
        const bool hasInteractiveStart = startValues.size(rt) != 0;
        Presentation start{};
        Presentation target;
        const SpringAnimation animation{
            args[3].asNumber(), args[4].asNumber(), args[5].asNumber(),
            args[6].asNumber(), boolArg(args, count, 7),
            static_cast<int32_t>(args[8].asNumber())};
        if (!validDriverId(driverId) ||
            (hasInteractiveStart &&
             (startValues.size(rt) != kPresentationStride ||
              !presentationAt(rt, startValues, 0, start))) ||
            targetValues.size(rt) != kPresentationStride ||
            !presentationAt(rt, targetValues, 0, target) ||
            !std::isfinite(animation.mass) ||
            !std::isfinite(animation.stiffness) ||
            !std::isfinite(animation.damping) ||
            !std::isfinite(animation.initialVelocity) || animation.mass <= 0 ||
            animation.stiffness <= 0 || animation.damping < 0) {
          return Value(0);
        }
        return Value(animateSpring(
            static_cast<uint64_t>(driverId),
            {hasInteractiveStart, start, startStampArg(args, count, 9)},
            target,
            animation));
      });

  setHostFunction(
      runtime, bindings, "animateKeyframes", 7,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 6 || !args[0].isNumber() || !args[1].isObject() ||
            !args[1].getObject(rt).isArray(rt) || !args[2].isObject() ||
            !args[2].getObject(rt).isArray(rt) || !args[4].isObject() ||
            !args[4].getObject(rt).isArray(rt)) {
          return Value(0);
        }
        const double driverId = args[0].asNumber();
        const Array startValues = args[1].getObject(rt).getArray(rt);
        const Array targetValues = args[2].getObject(rt).getArray(rt);
        const bool hasInteractiveStart = startValues.size(rt) != 0;
        Presentation start{};
        Presentation target;
        const double durationMs = args[3].asNumber();
        const int32_t reduceMotion = static_cast<int32_t>(args[5].asNumber());
        Array frames = args[4].getObject(rt).getArray(rt);
        const size_t length = frames.size(rt);
        if (!validDriverId(driverId) ||
            (hasInteractiveStart &&
             (startValues.size(rt) != kPresentationStride ||
              !presentationAt(rt, startValues, 0, start))) ||
            targetValues.size(rt) != kPresentationStride ||
            !presentationAt(rt, targetValues, 0, target) ||
            !std::isfinite(durationMs) ||
            length < kKeyframeStride * 2 || length % kKeyframeStride != 0) {
          return Value(0);
        }
        std::vector<Keyframe> keyframes;
        keyframes.reserve(length / kKeyframeStride);
        double previousOffset = -1;
        for (size_t index = 0; index < length; index += kKeyframeStride) {
          double offset;
          Presentation frame;
          if (!numberAt(rt, frames, index, offset) ||
              !presentationAt(rt, frames, index + 1, frame) ||
              offset < 0 || offset > 1 || offset <= previousOffset) {
            return Value(0);
          }
          previousOffset = offset;
          keyframes.push_back({offset, frame});
        }
        if (keyframes.front().offset != 0 || keyframes.back().offset != 1) {
          return Value(0);
        }
        return Value(animateKeyframes(
            static_cast<uint64_t>(driverId),
            {hasInteractiveStart, start, startStampArg(args, count, 6)},
            target,
            durationMs,
            std::move(keyframes),
            reduceMotion));
      });

  setHostFunction(
      runtime, bindings, "rejectAnimation", 1,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 1 || !validDriverId(args[0].asNumber())) return Value(0);
        return Value(rejectAnimation(
            static_cast<uint64_t>(args[0].asNumber())));
      });

  setHostFunction(
      runtime, bindings, "cancelAnimation", 3,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 3 || !validDriverId(args[0].asNumber())) {
          return cancelResultArray(
              rt, false, {{0, 0, 0, 0, 0}, 0, 0});
        }
        const CancelResult result = cancelAnimation(
            static_cast<uint64_t>(args[0].asNumber()),
            static_cast<int32_t>(args[1].asNumber()),
            static_cast<int32_t>(args[2].asNumber()) == 1);
        return cancelResultArray(
            rt, result.handled, result.presentation);
      });

  setHostFunction(
      runtime, bindings, "destroyDriver", 1,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count >= 1 && validDriverId(args[0].asNumber())) {
          destroyDriver(static_cast<uint64_t>(args[0].asNumber()));
        }
        return Value::undefined();
      });

  setHostFunction(
      runtime, bindings, "onClipAnimationComplete", 1,
      [state](Runtime &rt, const Value &, const Value *args, size_t count)
          -> Value {
        if (count < 1 || !args[0].isObject() ||
            !args[0].getObject(rt).isFunction(rt)) {
          return Value::undefined();
        }
        auto listener = std::make_shared<Function>(
            args[0].getObject(rt).getFunction(rt));
        const int32_t listenerId = ++state->nextListenerId;
        state->listeners.emplace(listenerId, std::move(listener));
        Object subscription(rt);
        setHostFunction(
            rt, subscription, "remove", 0,
            [state, listenerId](
                Runtime &, const Value &, const Value *, size_t) -> Value {
              state->listeners.erase(listenerId);
              return Value::undefined();
            });
        return subscription;
      });

  setHostFunction(
      runtime, bindings, "onClipGroupAnimationComplete", 1,
      [state](Runtime &rt, const Value &, const Value *args, size_t count)
          -> Value {
        if (count < 1 || !args[0].isObject() ||
            !args[0].getObject(rt).isFunction(rt)) {
          return Value::undefined();
        }
        auto listener = std::make_shared<Function>(
            args[0].getObject(rt).getFunction(rt));
        const int32_t listenerId = ++state->nextListenerId;
        state->groupListeners.emplace(listenerId, std::move(listener));
        Object subscription(rt);
        setHostFunction(
            rt, subscription, "remove", 0,
            [state, listenerId](
                Runtime &, const Value &, const Value *, size_t) -> Value {
              state->groupListeners.erase(listenerId);
              return Value::undefined();
            });
        return subscription;
      });

  runtime.global().setProperty(runtime, "__SmoothClipView", bindings);
}

void invalidateBindings() {
  // Runs from SmoothClipModule.invalidate() on the JS thread while the
  // runtime is still alive: completions must stop (the CallInvoker is about
  // to die) and the listener jsi::Functions must be released against their
  // own runtime.
  auto state = bindingsState();
  clearCompletionCallback(state.get());
  clearGroupCompletionCallback(state.get());
  state->listeners.clear();
  state->groupListeners.clear();
  state->runtime = nullptr;
  state->callInvoker = nullptr;
}

} // namespace smoothclip

// --- JNI surface -----------------------------------------------------------

namespace {

using namespace facebook;

jni::local_ref<BindingsInstallerHolder::javaobject> getBindingsInstaller(
    jni::alias_ref<jni::JObject>) {
  return BindingsInstallerHolder::newObjectCxxArgs(
      [](jsi::Runtime &runtime, const std::shared_ptr<CallInvoker> &callInvoker) {
        smoothclip::installBindings(runtime, callInvoker);
      });
}

void nativeRegisterView(
    jni::alias_ref<jni::JObject>,
    jdouble driverId,
    jni::alias_ref<smoothclip::JSmoothClipView> view,
    jdouble x,
    jdouble y,
    jdouble width,
    jdouble height,
    jdouble topLeftRadius,
    jdouble topRightRadius,
    jdouble bottomRightRadius,
    jdouble bottomLeftRadius,
    jint curveCode,
    jdouble contentTranslateX,
    jdouble contentTranslateY,
    jdouble contentScale,
    jboolean shadowEnabled,
    jdouble shadowRed,
    jdouble shadowGreen,
    jdouble shadowBlue,
    jdouble shadowAlpha,
    jdouble shadowOffsetX,
    jdouble shadowOffsetY,
    jdouble shadowBlurRadius,
    jdouble shadowSpreadDistance,
    jdouble density,
    jdouble widthPx,
    jdouble heightPx,
    jboolean lifecycleVisible) {
  if (driverId <= 0 || !std::isfinite(driverId) || !std::isfinite(x) ||
      !std::isfinite(y) || !std::isfinite(width) || !std::isfinite(height) ||
      !std::isfinite(topLeftRadius) || !std::isfinite(topRightRadius) ||
      !std::isfinite(bottomRightRadius) || !std::isfinite(bottomLeftRadius) ||
      !std::isfinite(contentTranslateX) ||
      !std::isfinite(contentTranslateY) || !std::isfinite(contentScale) ||
      !std::isfinite(shadowRed) || !std::isfinite(shadowGreen) ||
      !std::isfinite(shadowBlue) || !std::isfinite(shadowAlpha) ||
      !std::isfinite(shadowOffsetX) ||
      !std::isfinite(shadowOffsetY) || !std::isfinite(shadowBlurRadius) ||
      !std::isfinite(shadowSpreadDistance) || contentScale <= 0 ||
      shadowRed < 0 || shadowRed > 1 || shadowGreen < 0 || shadowGreen > 1 ||
      shadowBlue < 0 || shadowBlue > 1 || shadowAlpha < 0 || shadowAlpha > 1 ||
      shadowBlurRadius < 0 ||
      (curveCode != static_cast<jint>(smoothclip::ClipCurve::Circular) &&
       curveCode != static_cast<jint>(smoothclip::ClipCurve::Continuous))) {
    return;
  }
  smoothclip::Geometry geometry{x, y, width, height, 0.0};
  geometry.topLeftRadius = topLeftRadius;
  geometry.topRightRadius = topRightRadius;
  geometry.bottomRightRadius = bottomRightRadius;
  geometry.bottomLeftRadius = bottomLeftRadius;
  geometry.curve = static_cast<smoothclip::ClipCurve>(curveCode);
  if (topLeftRadius == topRightRadius && topLeftRadius == bottomRightRadius &&
      topLeftRadius == bottomLeftRadius) {
    geometry.radius = topLeftRadius;
  }
  smoothclip::Shadow shadow{
      shadowEnabled != 0,
      shadowRed,
      shadowGreen,
      shadowBlue,
      shadowAlpha,
      shadowOffsetX,
      shadowOffsetY,
      shadowBlurRadius,
      shadowSpreadDistance};
  smoothclip::registerViewAndroid(
      static_cast<uint64_t>(driverId),
      view,
      smoothclip::Presentation{
          geometry, contentTranslateX, contentTranslateY, contentScale, shadow},
      density,
      widthPx,
      heightPx,
      lifecycleVisible != 0);
}

void nativeSetViewHostGeometry(
    jni::alias_ref<jni::JObject>,
    jdouble driverId,
    jni::alias_ref<smoothclip::JSmoothClipView> view,
    jdouble density,
    jdouble widthPx,
    jdouble heightPx) {
  if (driverId <= 0 || !std::isfinite(driverId)) return;
  smoothclip::setViewHostGeometryAndroid(
      static_cast<uint64_t>(driverId), view, density, widthPx, heightPx);
}

void nativeUnregisterView(
    jni::alias_ref<jni::JObject>,
    jdouble driverId,
    jni::alias_ref<smoothclip::JSmoothClipView> view) {
  if (driverId <= 0 || !std::isfinite(driverId)) return;
  smoothclip::unregisterViewAndroid(static_cast<uint64_t>(driverId), view);
}

void nativeSetViewLifecycleVisibility(
    jni::alias_ref<jni::JObject>,
    jdouble driverId,
    jni::alias_ref<smoothclip::JSmoothClipView> view,
    jboolean lifecycleVisible) {
  if (driverId <= 0 || !std::isfinite(driverId)) return;
  smoothclip::setViewLifecycleVisibilityAndroid(
      static_cast<uint64_t>(driverId), view, lifecycleVisible != 0);
}

void nativeInvalidate(jni::alias_ref<jni::JObject>) {
  smoothclip::invalidateBindings();
}

void nativeOnFrame(jni::alias_ref<jni::JObject>, jlong frameTimeNanos) {
  smoothclip::onFrameAndroid(static_cast<double>(frameTimeNanos) / 1e9);
}

} // namespace

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *) {
  return facebook::jni::initialize(vm, [] {
    facebook::jni::registerNatives(
        "com/smoothclipview/SmoothClipBindings",
        {
            makeNativeMethod("getBindingsInstaller", getBindingsInstaller),
            makeNativeMethod("nativeRegisterView", nativeRegisterView),
            makeNativeMethod(
                "nativeSetViewHostGeometry", nativeSetViewHostGeometry),
            makeNativeMethod("nativeUnregisterView", nativeUnregisterView),
            makeNativeMethod(
                "nativeSetViewLifecycleVisibility",
                nativeSetViewLifecycleVisibility),
            makeNativeMethod("nativeInvalidate", nativeInvalidate),
            makeNativeMethod("nativeOnFrame", nativeOnFrame),
        });
  });
}
