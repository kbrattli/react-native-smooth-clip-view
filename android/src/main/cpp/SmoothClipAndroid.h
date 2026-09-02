#pragma once

#include <ReactCommon/CallInvoker.h>
#include <fbjni/fbjni.h>
#include <jsi/jsi.h>

#include <memory>

#include "SmoothClipRegistry.h"
#include "SmoothClipSharedGeometry.h"

namespace smoothclip {

// fbjni wrapper around com.smoothclipview.SmoothClipView. Kotlin remains a thin
// outline clipper while all driver state lives in the shared C++ registry.
struct JSmoothClipView : facebook::jni::JavaClass<JSmoothClipView> {
  static constexpr auto kJavaDescriptor = "Lcom/smoothclipview/SmoothClipView;";

  void applyClip(const Presentation &presentation) const;
  void applyClipPx(
      const CanonicalClip &clip,
      double contentTranslateXPx,
      double contentTranslateYPx,
      double contentScale,
      const Shadow &shadowPx) const;
  void setAutonomousMotion(bool active) const;
};

// Called from Kotlin (SmoothClipViewManager) on the UI thread when a Fabric
// view mounts/unmounts. The registry retains a global ref for the view.
void registerViewAndroid(
    uint64_t driverId,
    facebook::jni::alias_ref<JSmoothClipView> view,
    Presentation initialPresentation,
    double density,
    double hostWidthPx,
    double hostHeightPx,
    bool lifecycleVisible);
// Refreshes a registered view's density / host size (px) and synchronously
// redelivers the driver's raw canonical value. Host metrics only participate
// in lifecycle readiness; the view itself owns final viewport cropping.
void setViewHostGeometryAndroid(
    uint64_t driverId,
    facebook::jni::alias_ref<JSmoothClipView> view,
    double density,
    double hostWidthPx,
    double hostHeightPx);
void unregisterViewAndroid(
    uint64_t driverId,
    facebook::jni::alias_ref<JSmoothClipView> view);
// Pushes attachment/window visibility independently of host geometry. The
// registry combines both signals into its displayability/participant state.
void setViewLifecycleVisibilityAndroid(
    uint64_t driverId,
    facebook::jni::alias_ref<JSmoothClipView> view,
    bool lifecycleVisible);

// Advances the registry frame loop. Called from Kotlin (SmoothClipBindings)
// inside Choreographer#doFrame with the frame's vsync timestamp converted to
// seconds; never lets a failure unwind back into doFrame.
void onFrameAndroid(double frameTimeS);

// Non-destructive snapshot for the public snapshotCurrent binding.
// beginInteraction remains the explicit ownership-taking/cancelling operation.
Presentation snapshotCurrentAndroid(uint64_t driverId);

// Installs `global.__SmoothClipView` (worklet-callable host functions) into the
// JS runtime and wires native animation completion delivery through the
// CallInvoker. Invoked by the TurboModule BindingsInstaller.
void installBindings(
    facebook::jsi::Runtime &runtime,
    const std::shared_ptr<facebook::react::CallInvoker> &callInvoker);

// Releases the listener functions and completion sink while the JS runtime is
// still alive. Called from SmoothClipModule.invalidate() during host teardown.
void invalidateBindings();

} // namespace smoothclip
