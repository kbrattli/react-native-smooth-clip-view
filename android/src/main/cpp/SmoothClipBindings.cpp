#include "SmoothClipAndroid.h"

#include <ReactCommon/BindingsInstallerHolder.h>
#include <ReactCommon/CallInvoker.h>
#include <fbjni/fbjni.h>
#include <jsi/jsi.h>

#include <cmath>
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

bool finitePresentation(const Presentation &presentation) {
  return std::isfinite(presentation.clip.x) &&
      std::isfinite(presentation.clip.y) &&
      std::isfinite(presentation.clip.width) &&
      std::isfinite(presentation.clip.height) &&
      std::isfinite(presentation.clip.radius) &&
      std::isfinite(presentation.contentTranslateX) &&
      std::isfinite(presentation.contentTranslateY);
}

bool boolArg(const Value *args, size_t count, size_t index) {
  return index < count && args[index].isBool() && args[index].getBool();
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

struct BindingsState {
  Runtime *runtime = nullptr;
  std::shared_ptr<CallInvoker> callInvoker;
  std::unordered_map<int32_t, std::shared_ptr<Function>> listeners;
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

  Object bindings(runtime);

  setHostFunction(
      runtime, bindings, "setClipPresentation", 9,
      [](Runtime &rt, const Value &, const Value *args, size_t count) -> Value {
        if (count < 9) return Value::undefined();
        const double driverId = args[0].asNumber();
        const Presentation presentation = presentationFromArgs(args, 1);
        const bool takeOwnership = boolArg(args, count, 8);
        if (validDriverId(driverId) && finitePresentation(presentation)) {
          setPresentation(
              static_cast<uint64_t>(driverId), presentation, takeOwnership);
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
      runtime, bindings, "animateTiming", 22,
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
            {boolArg(args, count, 1), start},
            target,
            animation));
      });

  setHostFunction(
      runtime, bindings, "animateSpring", 22,
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
            !std::isfinite(animation.initialVelocity) ||
            animation.mass <= 0 || animation.stiffness <= 0 ||
            animation.damping < 0) {
          return Value(0);
        }
        return Value(animateSpring(
            static_cast<uint64_t>(driverId),
            {boolArg(args, count, 1), start},
            target,
            animation));
      });

  setHostFunction(
      runtime, bindings, "animateKeyframes", 19,
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
            {boolArg(args, count, 1), start},
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

  runtime.global().setProperty(runtime, "__SmoothClipView", bindings);
}

void invalidateBindings() {
  // Runs from SmoothClipModule.invalidate() on the JS thread while the
  // runtime is still alive: completions must stop (the CallInvoker is about
  // to die) and the listener jsi::Functions must be released against their
  // own runtime.
  auto state = bindingsState();
  clearCompletionCallback(state.get());
  state->listeners.clear();
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
    jdouble heightPx) {
  if (driverId <= 0 || !std::isfinite(driverId)) return;
  smoothclip::registerViewAndroid(
      static_cast<uint64_t>(driverId),
      view,
      smoothclip::Presentation{
          {x, y, width, height, radius}, contentTranslateX, contentTranslateY},
      density,
      widthPx,
      heightPx);
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

void nativeViewBecameDisplayable(
    jni::alias_ref<jni::JObject>,
    jdouble driverId,
    jni::alias_ref<smoothclip::JSmoothClipView> view) {
  if (driverId <= 0 || !std::isfinite(driverId)) return;
  smoothclip::viewBecameDisplayableAndroid(
      static_cast<uint64_t>(driverId), view);
}

void nativeInvalidate(jni::alias_ref<jni::JObject>) {
  smoothclip::invalidateBindings();
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
                "nativeViewBecameDisplayable", nativeViewBecameDisplayable),
            makeNativeMethod("nativeInvalidate", nativeInvalidate),
        });
  });
}
