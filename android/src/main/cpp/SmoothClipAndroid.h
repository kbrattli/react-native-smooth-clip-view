#pragma once

#include <ReactCommon/CallInvoker.h>
#include <fbjni/fbjni.h>
#include <jsi/jsi.h>

#include <memory>

#include "SmoothClipRegistry.h"
#include "SmoothClipSharedGeometry.h"

namespace smoothclip {

// fbjni wrapper around com.smoothclipview.SmoothClipView. Only the primitive
// clip setter is invoked from native, so the Kotlin view stays a thin outline
// clipper while all driver state lives in the shared C++ registry.
struct JSmoothClipView : facebook::jni::JavaClass<JSmoothClipView> {
  static constexpr auto kJavaDescriptor = "Lcom/smoothclipview/SmoothClipView;";

  void applyClip(const Presentation &presentation) const;
  void applyClipPx(
      const NormalizedClip &clip,
      double contentTranslateXPx,
      double contentTranslateYPx) const;
  bool isViewAttachedToWindow() const;
};

// Called from Kotlin (SmoothClipViewManager) on the UI thread when a Fabric
// view mounts/unmounts. The registry retains a global ref for the view.
void registerViewAndroid(
    uint64_t driverId,
    facebook::jni::alias_ref<JSmoothClipView> view,
    Presentation initialPresentation,
    double density,
    double hostWidthPx,
    double hostHeightPx);
// Refreshes a registered view's density / host size (px) and synchronously
// redelivers the driver's visible value pre-normalized against them.
void setViewHostGeometryAndroid(
    uint64_t driverId,
    facebook::jni::alias_ref<JSmoothClipView> view,
    double density,
    double hostWidthPx,
    double hostHeightPx);
void unregisterViewAndroid(
    uint64_t driverId,
    facebook::jni::alias_ref<JSmoothClipView> view);
// Called from Kotlin when a registered view attaches to a window. A latched
// animation may only start once a registered view can actually produce a
// visible frame (attached AND has host geometry); otherwise its clock would
// burn progress no one can see.
void viewBecameDisplayableAndroid(
    uint64_t driverId,
    facebook::jni::alias_ref<JSmoothClipView> view);

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
