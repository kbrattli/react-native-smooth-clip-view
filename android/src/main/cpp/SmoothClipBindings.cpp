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

bool finitePresentation(const Presentation &presentation) {
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

bool finiteV2Presentation(const Presentation &presentation) {
  return finitePresentation(presentation) &&
      std::isfinite(presentation.clip.topLeftRadius) &&
      std::isfinite(presentation.clip.topRightRadius) &&
      std::isfinite(presentation.clip.bottomRightRadius) &&
      std::isfinite(presentation.clip.bottomLeftRadius);
}

bool boolArg(const Value *args, size_t count, size_t index) {
  return index < count && args[index].isBool() && args[index].getBool();
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

Presentation presentationFromArgs(const Value *args, size_t offset) {
  return Presentation{
      {args[offset].asNumber(),
       args[offset + 1].asNumber(),
       args[offset + 2].asNumber(),
       args[offset + 3].asNumber(),
       args[offset + 4].asNumber()},
      args[offset + 5].asNumber(),
      args[offset + 6].asNumber()};
}

Presentation presentationV2FromArgs(const Value *args, size_t offset) {
  Geometry geometry{
      args[offset].asNumber(),
      args[offset + 1].asNumber(),
      args[offset + 2].asNumber(),
      args[offset + 3].asNumber(),
      0.0};
  geometry.topLeftRadius = args[offset + 4].asNumber();
  geometry.topRightRadius = args[offset + 5].asNumber();
  geometry.bottomRightRadius = args[offset + 6].asNumber();
  geometry.bottomLeftRadius = args[offset + 7].asNumber();
  const double curveCode = args[offset + 8].asNumber();
  geometry.curve = curveCode == static_cast<double>(ClipCurve::Continuous)
      ? ClipCurve::Continuous
      : curveCode == static_cast<double>(ClipCurve::Circular)
      ? ClipCurve::Circular
      : static_cast<ClipCurve>(-1);
  if (geometry.topLeftRadius == geometry.topRightRadius &&
      geometry.topLeftRadius == geometry.bottomRightRadius &&
      geometry.topLeftRadius == geometry.bottomLeftRadius) {
    geometry.radius = geometry.topLeftRadius;
  }
  return Presentation{
      geometry,
      args[offset + 9].asNumber(),
      args[offset + 10].asNumber(),
      args[offset + 11].asNumber()};
}

Presentation presentationV2FromArray(
    Runtime &runtime,
    const Array &values,
    size_t offset) {
  Geometry geometry{
      values.getValueAtIndex(runtime, offset).asNumber(),
      values.getValueAtIndex(runtime, offset + 1).asNumber(),
      values.getValueAtIndex(runtime, offset + 2).asNumber(),
      values.getValueAtIndex(runtime, offset + 3).asNumber(),
      0.0};
  geometry.topLeftRadius =
      values.getValueAtIndex(runtime, offset + 4).asNumber();
  geometry.topRightRadius =
      values.getValueAtIndex(runtime, offset + 5).asNumber();
  geometry.bottomRightRadius =
      values.getValueAtIndex(runtime, offset + 6).asNumber();
  geometry.bottomLeftRadius =
      values.getValueAtIndex(runtime, offset + 7).asNumber();
  const double curveCode =
      values.getValueAtIndex(runtime, offset + 8).asNumber();
  geometry.curve = curveCode == static_cast<double>(ClipCurve::Continuous)
      ? ClipCurve::Continuous
      : curveCode == static_cast<double>(ClipCurve::Circular)
      ? ClipCurve::Circular
      : static_cast<ClipCurve>(-1);
  if (geometry.topLeftRadius == geometry.topRightRadius &&
      geometry.topLeftRadius == geometry.bottomRightRadius &&
      geometry.topLeftRadius == geometry.bottomLeftRadius) {
    geometry.radius = geometry.topLeftRadius;
  }
  return Presentation{
      geometry,
      values.getValueAtIndex(runtime, offset + 9).asNumber(),
      values.getValueAtIndex(runtime, offset + 10).asNumber(),
      values.getValueAtIndex(runtime, offset + 11).asNumber()};
}

Array presentationArray(Runtime &runtime, const Presentation &presentation) {
  Array result(runtime, 7);
  result.setValueAtIndex(runtime, 0, presentation.clip.x);
  result.setValueAtIndex(runtime, 1, presentation.clip.y);
  result.setValueAtIndex(runtime, 2, presentation.clip.width);
  result.setValueAtIndex(runtime, 3, presentation.clip.height);
  result.setValueAtIndex(runtime, 4, presentation.clip.radius);
  result.setValueAtIndex(runtime, 5, presentation.contentTranslateX);
  result.setValueAtIndex(runtime, 6, presentation.contentTranslateY);
  return result;
}

Array presentationArrayV2(Runtime &runtime, const Presentation &presentation) {
  Array result(runtime, 12);
  result.setValueAtIndex(runtime, 0, presentation.clip.x);
  result.setValueAtIndex(runtime, 1, presentation.clip.y);
  result.setValueAtIndex(runtime, 2, presentation.clip.width);
  result.setValueAtIndex(runtime, 3, presentation.clip.height);
  result.setValueAtIndex(
      runtime,
      4,
      SmoothClipResolvedRadius(
          presentation.clip.topLeftRadius, presentation.clip.radius));
  result.setValueAtIndex(
      runtime,
      5,
      SmoothClipResolvedRadius(
          presentation.clip.topRightRadius, presentation.clip.radius));
  result.setValueAtIndex(
      runtime,
      6,
      SmoothClipResolvedRadius(
          presentation.clip.bottomRightRadius, presentation.clip.radius));
  result.setValueAtIndex(
      runtime,
      7,
      SmoothClipResolvedRadius(
          presentation.clip.bottomLeftRadius, presentation.clip.radius));
  result.setValueAtIndex(
      runtime, 8, static_cast<double>(presentation.clip.curve));
  result.setValueAtIndex(runtime, 9, presentation.contentTranslateX);
  result.setValueAtIndex(runtime, 10, presentation.contentTranslateY);
  result.setValueAtIndex(runtime, 11, presentation.contentScale);
  return result;
}

Array cancelResultArray(
    Runtime &runtime,
    bool handled,
    const Presentation &presentation) {
  Array result(runtime, 8);
  // JS checks `values[0] !== 1`, so the handled flag must be a number.
  result.setValueAtIndex(runtime, 0, handled ? 1.0 : 0.0);
  result.setValueAtIndex(runtime, 1, presentation.clip.x);
  result.setValueAtIndex(runtime, 2, presentation.clip.y);
  result.setValueAtIndex(runtime, 3, presentation.clip.width);
  result.setValueAtIndex(runtime, 4, presentation.clip.height);
  result.setValueAtIndex(runtime, 5, presentation.clip.radius);
  result.setValueAtIndex(runtime, 6, presentation.contentTranslateX);
  result.setValueAtIndex(runtime, 7, presentation.contentTranslateY);
  return result;
}

Array cancelResultArrayV2(
    Runtime &runtime,
    bool handled,
    const Presentation &presentation) {
  Array result(runtime, 13);
  result.setValueAtIndex(runtime, 0, handled ? 1.0 : 0.0);
  result.setValueAtIndex(runtime, 1, presentation.clip.x);
  result.setValueAtIndex(runtime, 2, presentation.clip.y);
  result.setValueAtIndex(runtime, 3, presentation.clip.width);
  result.setValueAtIndex(runtime, 4, presentation.clip.height);
  result.setValueAtIndex(
      runtime,
      5,
      SmoothClipResolvedRadius(
          presentation.clip.topLeftRadius, presentation.clip.radius));
  result.setValueAtIndex(
      runtime,
      6,
      SmoothClipResolvedRadius(
          presentation.clip.topRightRadius, presentation.clip.radius));
  result.setValueAtIndex(
      runtime,
      7,
      SmoothClipResolvedRadius(
          presentation.clip.bottomRightRadius, presentation.clip.radius));
  result.setValueAtIndex(
      runtime,
      8,
      SmoothClipResolvedRadius(
          presentation.clip.bottomLeftRadius, presentation.clip.radius));
  result.setValueAtIndex(
      runtime, 9, static_cast<double>(presentation.clip.curve));
  result.setValueAtIndex(runtime, 10, presentation.contentTranslateX);
  result.setValueAtIndex(runtime, 11, presentation.contentTranslateY);
  result.setValueAtIndex(runtime, 12, presentation.contentScale);
  return result;
}

Array snapshotsArrayV2(
    Runtime &runtime,
    const std::vector<DriverSnapshot> &snapshots) {
  Array result(runtime, snapshots.size() * 13);
  size_t offset = 0;
  for (const DriverSnapshot &snapshot : snapshots) {
    result.setValueAtIndex(runtime, offset++, snapshot.ready ? 1.0 : 0.0);
    const Presentation &presentation = snapshot.presentation;
    result.setValueAtIndex(runtime, offset++, presentation.clip.x);
    result.setValueAtIndex(runtime, offset++, presentation.clip.y);
    result.setValueAtIndex(runtime, offset++, presentation.clip.width);
    result.setValueAtIndex(runtime, offset++, presentation.clip.height);
    result.setValueAtIndex(
        runtime,
        offset++,
        SmoothClipResolvedRadius(
            presentation.clip.topLeftRadius, presentation.clip.radius));
    result.setValueAtIndex(
        runtime,
        offset++,
        SmoothClipResolvedRadius(
            presentation.clip.topRightRadius, presentation.clip.radius));
    result.setValueAtIndex(
        runtime,
        offset++,
        SmoothClipResolvedRadius(
            presentation.clip.bottomRightRadius, presentation.clip.radius));
    result.setValueAtIndex(
        runtime,
        offset++,
        SmoothClipResolvedRadius(
            presentation.clip.bottomLeftRadius, presentation.clip.radius));
    result.setValueAtIndex(
        runtime, offset++, static_cast<double>(presentation.clip.curve));
    result.setValueAtIndex(runtime, offset++, presentation.contentTranslateX);
    result.setValueAtIndex(runtime, offset++, presentation.contentTranslateY);
    result.setValueAtIndex(runtime, offset++, presentation.contentScale);
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
    const double value = values.getValueAtIndex(runtime, index).asNumber();
    if (!validDriverId(value) ||
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
  if (length < 26 || length % 26 != 0) return false;
  entries.reserve(length / 26);
  for (size_t index = 0; index < length; index += 26) {
    const double driverId = values.getValueAtIndex(runtime, index).asNumber();
    const double hasFromValue =
        values.getValueAtIndex(runtime, index + 1).asNumber();
    const double fromCurve =
        values.getValueAtIndex(runtime, index + 10).asNumber();
    const double targetCurve =
        values.getValueAtIndex(runtime, index + 22).asNumber();
    const Presentation from =
        presentationV2FromArray(runtime, values, index + 2);
    const Presentation target =
        presentationV2FromArray(runtime, values, index + 14);
    if (!validDriverId(driverId) ||
        (hasFromValue != 0.0 && hasFromValue != 1.0) ||
        !validCurve(fromCurve) || !validCurve(targetCurve) ||
        !finiteV2Presentation(from) || !finiteV2Presentation(target)) {
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
    if (length - index < 27) return false;
    const double driverId = values.getValueAtIndex(runtime, index).asNumber();
    const double hasFromValue =
        values.getValueAtIndex(runtime, index + 1).asNumber();
    const double fromCurve =
        values.getValueAtIndex(runtime, index + 10).asNumber();
    const double targetCurve =
        values.getValueAtIndex(runtime, index + 22).asNumber();
    const double frameCountValue =
        values.getValueAtIndex(runtime, index + 26).asNumber();
    const Presentation from =
        presentationV2FromArray(runtime, values, index + 2);
    const Presentation target =
        presentationV2FromArray(runtime, values, index + 14);
    if (!validDriverId(driverId) ||
        (hasFromValue != 0.0 && hasFromValue != 1.0) ||
        !validCurve(fromCurve) || !validCurve(targetCurve) ||
        !finiteV2Presentation(from) || !finiteV2Presentation(target) ||
        !std::isfinite(frameCountValue) || frameCountValue < 2 ||
        std::floor(frameCountValue) != frameCountValue) {
      return false;
    }
    const size_t frameCount = static_cast<size_t>(frameCountValue);
    index += 27;
    if (frameCount > (length - index) / 13) return false;
    std::vector<Keyframe> keyframes;
    keyframes.reserve(frameCount);
    double previousOffset = -1;
    for (size_t frameIndex = 0; frameIndex < frameCount; frameIndex += 1) {
      const double offset = values.getValueAtIndex(runtime, index).asNumber();
      const double curve =
          values.getValueAtIndex(runtime, index + 9).asNumber();
      const Presentation presentation =
          presentationV2FromArray(runtime, values, index + 1);
      if (!std::isfinite(offset) || offset < 0 || offset > 1 ||
          offset <= previousOffset || !validCurve(curve) ||
          !finiteV2Presentation(presentation)) {
        return false;
      }
      previousOffset = offset;
      keyframes.push_back({offset, presentation});
      index += 13;
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
      runtime, bindings, "getPresentationProtocolVersion", 0,
      [](Runtime &, const Value &, const Value *, size_t) -> Value {
        return Value(2);
      });

  setHostFunction(
      runtime, bindings, "supportsAutonomousComplexPathAnimation", 0,
      [](Runtime &, const Value &, const Value *, size_t) -> Value {
        // Static complex clipping is available. Autonomous complex-path
        // animation is deliberately gated off until physical-device sampling
        // proves the release tolerance and frame-time requirements.
        return Value(false);
      });

  setHostFunction(
      runtime, bindings, "beginGroupInteractionV2", 1,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 1 || !args[0].isObject() ||
            !args[0].getObject(rt).isArray(rt)) {
          return Array(rt, 0);
        }
        Array values = args[0].getObject(rt).getArray(rt);
        const std::vector<uint64_t> driverIds = driverIdsFromArray(rt, values);
        if (driverIds.empty()) return Array(rt, 0);
        return snapshotsArrayV2(rt, beginGroupInteraction(driverIds));
      });

  setHostFunction(
      runtime, bindings, "snapshotGroupV2", 1,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 1 || !args[0].isObject() ||
            !args[0].getObject(rt).isArray(rt)) {
          return Array(rt, 0);
        }
        Array values = args[0].getObject(rt).getArray(rt);
        const std::vector<uint64_t> driverIds = driverIdsFromArray(rt, values);
        if (driverIds.empty()) return Array(rt, 0);
        return snapshotsArrayV2(rt, snapshotGroup(driverIds));
      });

  setHostFunction(
      runtime, bindings, "setClipPresentationBatchV2", 1,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 1 || !args[0].isObject() ||
            !args[0].getObject(rt).isArray(rt)) {
          return Value(false);
        }
        Array values = args[0].getObject(rt).getArray(rt);
        const size_t length = values.size(rt);
        if (length < 13 || length % 13 != 0) return Value(false);
        std::vector<BatchEntry> entries;
        entries.reserve(length / 13);
        for (size_t index = 0; index < length; index += 13) {
          const double driverId =
              values.getValueAtIndex(rt, index).asNumber();
          const double curve =
              values.getValueAtIndex(rt, index + 9).asNumber();
          const Presentation presentation =
              presentationV2FromArray(rt, values, index + 1);
          if (!validDriverId(driverId) || !validCurve(curve) ||
              !finiteV2Presentation(presentation)) {
            return Value(false);
          }
          entries.push_back(
              {static_cast<uint64_t>(driverId), presentation});
        }
        return Value(setPresentationBatch(entries));
      });

  setHostFunction(
      runtime, bindings, "animateTimingGroupV2", 10,
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
      runtime, bindings, "animateSpringGroupV2", 10,
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
      runtime, bindings, "animateKeyframesGroupV2", 6,
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
      runtime, bindings, "cancelAnimationGroupV2", 2,
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
        return snapshotsArrayV2(
            rt,
            cancelAnimationGroup(
                static_cast<int32_t>(groupId),
                static_cast<GroupCancelBehavior>(
                    static_cast<int32_t>(behavior))));
      });

  setHostFunction(
      runtime, bindings, "setClipPresentation", 11,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 9) return Value::undefined();
        const double driverId = args[0].asNumber();
        const Presentation presentation = presentationFromArgs(args, 1);
        const bool takeOwnership = boolArg(args, count, 8);
        const bool overridePendingAnimation = boolArg(args, count, 9);
        // Optional trailing flag; absent means record (the pre-flag
        // behavior), so only an explicit false skips the velocity sample.
        const bool recordVelocity =
            !(count > 10 && args[10].isBool() && !args[10].getBool());
        if (validDriverId(driverId) && finitePresentation(presentation)) {
          setPresentation(
              static_cast<uint64_t>(driverId), presentation, takeOwnership,
              overridePendingAnimation, recordVelocity);
        }
        return Value::undefined();
      });

  setHostFunction(
      runtime, bindings, "setClipPresentationV2", 16,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 14) return Value::undefined();
        const double driverId = args[0].asNumber();
        const Presentation presentation = presentationV2FromArgs(args, 1);
        const bool takeOwnership = boolArg(args, count, 13);
        const bool overridePendingAnimation = boolArg(args, count, 14);
        const bool recordVelocity =
            !(count > 15 && args[15].isBool() && !args[15].getBool());
        if (validDriverId(driverId) && validCurve(args[9].asNumber()) &&
            finiteV2Presentation(presentation)) {
          setPresentation(
              static_cast<uint64_t>(driverId), presentation, takeOwnership,
              overridePendingAnimation, recordVelocity);
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
      runtime, bindings, "beginInteractionV2", 1,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 1 || !validDriverId(args[0].asNumber())) {
          return presentationArrayV2(rt, {{0, 0, 0, 0, 0}, 0, 0});
        }
        return presentationArrayV2(
            rt, beginInteraction(static_cast<uint64_t>(args[0].asNumber())));
      });

  setHostFunction(
      runtime, bindings, "snapshotCurrentV2", 1,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 1 || !validDriverId(args[0].asNumber())) {
          return presentationArrayV2(rt, {{0, 0, 0, 0, 0}, 0, 0});
        }
        return presentationArrayV2(
            rt,
            snapshotCurrentAndroid(
                static_cast<uint64_t>(args[0].asNumber())));
      });

  setHostFunction(
      runtime, bindings, "animateTiming", 23,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 22) return Value(0);
        const double driverId = args[0].asNumber();
        const Presentation start = presentationFromArgs(args, 2);
        const Presentation target = presentationFromArgs(args, 9);
        const TimingAnimation animation{
            args[16].asNumber(), args[17].asNumber(), args[18].asNumber(),
            args[19].asNumber(), args[20].asNumber(),
            static_cast<int32_t>(args[21].asNumber())};
        if (!validDriverId(driverId) || !finitePresentation(start) ||
            !finitePresentation(target) ||
            !std::isfinite(animation.durationMs)) {
          return Value(0);
        }
        return Value(animateTiming(
            static_cast<uint64_t>(driverId),
            {boolArg(args, count, 1), start, startStampArg(args, count, 22)},
            target,
            animation,
            AnimationValidationMode::LegacyV1));
      });

  setHostFunction(
      runtime, bindings, "animateTimingV2", 33,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 32) return Value(0);
        const double driverId = args[0].asNumber();
        const Presentation start = presentationV2FromArgs(args, 2);
        const Presentation target = presentationV2FromArgs(args, 14);
        const TimingAnimation animation{
            args[26].asNumber(), args[27].asNumber(), args[28].asNumber(),
            args[29].asNumber(), args[30].asNumber(),
            static_cast<int32_t>(args[31].asNumber())};
        if (!validDriverId(driverId) || !validCurve(args[10].asNumber()) ||
            !validCurve(args[22].asNumber()) ||
            !finiteV2Presentation(start) || !finiteV2Presentation(target) ||
            !std::isfinite(animation.durationMs)) {
          return Value(0);
        }
        return Value(animateTiming(
            static_cast<uint64_t>(driverId),
            {boolArg(args, count, 1), start, startStampArg(args, count, 32)},
            target,
            animation));
      });

  setHostFunction(
      runtime, bindings, "animateSpring", 23,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 22) return Value(0);
        const double driverId = args[0].asNumber();
        const Presentation start = presentationFromArgs(args, 2);
        const Presentation target = presentationFromArgs(args, 9);
        const SpringAnimation animation{
            args[16].asNumber(), args[17].asNumber(), args[18].asNumber(),
            args[19].asNumber(), boolArg(args, count, 20),
            static_cast<int32_t>(args[21].asNumber())};
        if (!validDriverId(driverId) || !finitePresentation(start) ||
            !finitePresentation(target) || !std::isfinite(animation.mass) ||
            !std::isfinite(animation.stiffness) ||
            !std::isfinite(animation.damping) ||
            !std::isfinite(animation.initialVelocity)) {
          return Value(0);
        }
        return Value(animateSpring(
            static_cast<uint64_t>(driverId),
            {boolArg(args, count, 1), start, startStampArg(args, count, 22)},
            target,
            animation,
            AnimationValidationMode::LegacyV1));
      });

  setHostFunction(
      runtime, bindings, "animateSpringV2", 33,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 32) return Value(0);
        const double driverId = args[0].asNumber();
        const Presentation start = presentationV2FromArgs(args, 2);
        const Presentation target = presentationV2FromArgs(args, 14);
        const SpringAnimation animation{
            args[26].asNumber(), args[27].asNumber(), args[28].asNumber(),
            args[29].asNumber(), boolArg(args, count, 30),
            static_cast<int32_t>(args[31].asNumber())};
        if (!validDriverId(driverId) || !validCurve(args[10].asNumber()) ||
            !validCurve(args[22].asNumber()) ||
            !finiteV2Presentation(start) || !finiteV2Presentation(target) ||
            !std::isfinite(animation.mass) ||
            !std::isfinite(animation.stiffness) ||
            !std::isfinite(animation.damping) ||
            !std::isfinite(animation.initialVelocity) || animation.mass <= 0 ||
            animation.stiffness <= 0 || animation.damping < 0) {
          return Value(0);
        }
        return Value(animateSpring(
            static_cast<uint64_t>(driverId),
            {boolArg(args, count, 1), start, startStampArg(args, count, 32)},
            target,
            animation));
      });

  setHostFunction(
      runtime, bindings, "animateKeyframes", 20,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 19 || !args[17].isObject() ||
            !args[17].getObject(rt).isArray(rt)) {
          return Value(0);
        }
        const double driverId = args[0].asNumber();
        const Presentation start = presentationFromArgs(args, 2);
        const Presentation target = presentationFromArgs(args, 9);
        const double durationMs = args[16].asNumber();
        const int32_t reduceMotion = static_cast<int32_t>(args[18].asNumber());
        Array frames = args[17].getObject(rt).getArray(rt);
        const size_t length = frames.size(rt);
        if (!validDriverId(driverId) || !finitePresentation(start) ||
            !finitePresentation(target) || !std::isfinite(durationMs) ||
            length < 16 || length % 8 != 0) {
          return Value(0);
        }
        std::vector<Keyframe> keyframes;
        keyframes.reserve(length / 8);
        double previousOffset = -1;
        for (size_t index = 0; index < length; index += 8) {
          const double offset = frames.getValueAtIndex(rt, index).asNumber();
          const Presentation frame{
              {frames.getValueAtIndex(rt, index + 1).asNumber(),
               frames.getValueAtIndex(rt, index + 2).asNumber(),
               frames.getValueAtIndex(rt, index + 3).asNumber(),
               frames.getValueAtIndex(rt, index + 4).asNumber(),
               frames.getValueAtIndex(rt, index + 5).asNumber()},
              frames.getValueAtIndex(rt, index + 6).asNumber(),
              frames.getValueAtIndex(rt, index + 7).asNumber()};
          if (!std::isfinite(offset) || offset < 0 || offset > 1 ||
              offset <= previousOffset || !finitePresentation(frame)) {
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
            {boolArg(args, count, 1), start, startStampArg(args, count, 19)},
            target,
            durationMs,
            std::move(keyframes),
            reduceMotion,
            AnimationValidationMode::LegacyV1));
      });

  setHostFunction(
      runtime, bindings, "animateKeyframesV2", 30,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 29 || !args[27].isObject() ||
            !args[27].getObject(rt).isArray(rt)) {
          return Value(0);
        }
        const double driverId = args[0].asNumber();
        const Presentation start = presentationV2FromArgs(args, 2);
        const Presentation target = presentationV2FromArgs(args, 14);
        const double durationMs = args[26].asNumber();
        const int32_t reduceMotion = static_cast<int32_t>(args[28].asNumber());
        Array frames = args[27].getObject(rt).getArray(rt);
        const size_t length = frames.size(rt);
        if (!validDriverId(driverId) || !validCurve(args[10].asNumber()) ||
            !validCurve(args[22].asNumber()) ||
            !finiteV2Presentation(start) || !finiteV2Presentation(target) ||
            !std::isfinite(durationMs) || length < 26 || length % 13 != 0) {
          return Value(0);
        }
        std::vector<Keyframe> keyframes;
        keyframes.reserve(length / 13);
        double previousOffset = -1;
        for (size_t index = 0; index < length; index += 13) {
          const double offset = frames.getValueAtIndex(rt, index).asNumber();
          const double curveCode =
              frames.getValueAtIndex(rt, index + 9).asNumber();
          const Presentation frame =
              presentationV2FromArray(rt, frames, index + 1);
          if (!std::isfinite(offset) || offset < 0 || offset > 1 ||
              offset <= previousOffset || !validCurve(curveCode) ||
              !finiteV2Presentation(frame)) {
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
            {boolArg(args, count, 1), start, startStampArg(args, count, 29)},
            target,
            durationMs,
            std::move(keyframes),
            reduceMotion));
      });

  setHostFunction(
      runtime, bindings, "animateTimingFromV2", 32,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 31) return Value(0);
        const double driverId = args[0].asNumber();
        const Presentation start = presentationV2FromArgs(args, 1);
        const Presentation target = presentationV2FromArgs(args, 13);
        const TimingAnimation animation{
            args[25].asNumber(), args[26].asNumber(), args[27].asNumber(),
            args[28].asNumber(), args[29].asNumber(),
            static_cast<int32_t>(args[30].asNumber())};
        if (!validDriverId(driverId) || !validCurve(args[9].asNumber()) ||
            !validCurve(args[21].asNumber()) ||
            !finiteV2Presentation(start) || !finiteV2Presentation(target) ||
            !std::isfinite(animation.durationMs)) {
          return Value(0);
        }
        return Value(animateTiming(
            static_cast<uint64_t>(driverId),
            {true, start, startStampArg(args, count, 31)},
            target,
            animation));
      });

  setHostFunction(
      runtime, bindings, "animateSpringFromV2", 32,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 31) return Value(0);
        const double driverId = args[0].asNumber();
        const Presentation start = presentationV2FromArgs(args, 1);
        const Presentation target = presentationV2FromArgs(args, 13);
        const SpringAnimation animation{
            args[25].asNumber(), args[26].asNumber(), args[27].asNumber(),
            args[28].asNumber(), boolArg(args, count, 29),
            static_cast<int32_t>(args[30].asNumber())};
        if (!validDriverId(driverId) || !validCurve(args[9].asNumber()) ||
            !validCurve(args[21].asNumber()) ||
            !finiteV2Presentation(start) || !finiteV2Presentation(target) ||
            !std::isfinite(animation.mass) ||
            !std::isfinite(animation.stiffness) ||
            !std::isfinite(animation.damping) ||
            !std::isfinite(animation.initialVelocity) || animation.mass <= 0 ||
            animation.stiffness <= 0 || animation.damping < 0) {
          return Value(0);
        }
        return Value(animateSpring(
            static_cast<uint64_t>(driverId),
            {true, start, startStampArg(args, count, 31)},
            target,
            animation));
      });

  setHostFunction(
      runtime, bindings, "animateKeyframesFromV2", 29,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 28 || !args[26].isObject() ||
            !args[26].getObject(rt).isArray(rt)) {
          return Value(0);
        }
        const double driverId = args[0].asNumber();
        const Presentation start = presentationV2FromArgs(args, 1);
        const Presentation target = presentationV2FromArgs(args, 13);
        const double durationMs = args[25].asNumber();
        const int32_t reduceMotion = static_cast<int32_t>(args[27].asNumber());
        Array frames = args[26].getObject(rt).getArray(rt);
        const size_t length = frames.size(rt);
        if (!validDriverId(driverId) || !validCurve(args[9].asNumber()) ||
            !validCurve(args[21].asNumber()) ||
            !finiteV2Presentation(start) || !finiteV2Presentation(target) ||
            !std::isfinite(durationMs) || length < 26 || length % 13 != 0) {
          return Value(0);
        }
        std::vector<Keyframe> keyframes;
        keyframes.reserve(length / 13);
        double previousOffset = -1;
        for (size_t index = 0; index < length; index += 13) {
          const double offset = frames.getValueAtIndex(rt, index).asNumber();
          const double frameCurve =
              frames.getValueAtIndex(rt, index + 9).asNumber();
          const Presentation frame =
              presentationV2FromArray(rt, frames, index + 1);
          if (!std::isfinite(offset) || offset < 0 || offset > 1 ||
              offset <= previousOffset || !validCurve(frameCurve) ||
              !finiteV2Presentation(frame)) {
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
            {true, start, startStampArg(args, count, 28)},
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
          return cancelResultArray(rt, false, {{0, 0, 0, 0, 0}, 0, 0});
        }
        const CancelResult result = cancelAnimation(
            static_cast<uint64_t>(args[0].asNumber()),
            static_cast<int32_t>(args[1].asNumber()),
            static_cast<int32_t>(args[2].asNumber()) == 1);
        return cancelResultArray(rt, result.handled, result.presentation);
      });

  setHostFunction(
      runtime, bindings, "cancelAnimationV2", 3,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 3 || !validDriverId(args[0].asNumber())) {
          return cancelResultArrayV2(
              rt, false, {{0, 0, 0, 0, 0}, 0, 0});
        }
        const CancelResult result = cancelAnimation(
            static_cast<uint64_t>(args[0].asNumber()),
            static_cast<int32_t>(args[1].asNumber()),
            static_cast<int32_t>(args[2].asNumber()) == 1);
        return cancelResultArrayV2(
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
    jdouble radius,
    jdouble contentTranslateX,
    jdouble contentTranslateY,
    jdouble density,
    jdouble widthPx,
    jdouble heightPx,
    jboolean lifecycleVisible) {
  if (driverId <= 0 || !std::isfinite(driverId)) return;
  smoothclip::registerViewAndroid(
      static_cast<uint64_t>(driverId),
      view,
      smoothclip::Presentation{
          {x, y, width, height, radius}, contentTranslateX, contentTranslateY},
      density,
      widthPx,
      heightPx,
      lifecycleVisible != 0);
}

void nativeRegisterViewV2(
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
      contentScale <= 0 ||
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
  smoothclip::registerViewAndroid(
      static_cast<uint64_t>(driverId),
      view,
      smoothclip::Presentation{
          geometry, contentTranslateX, contentTranslateY, contentScale},
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
            makeNativeMethod("nativeRegisterViewV2", nativeRegisterViewV2),
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
