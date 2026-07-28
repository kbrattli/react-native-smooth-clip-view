package com.smoothclipview

import com.facebook.proguard.annotations.DoNotStrip
import com.facebook.react.turbomodule.core.interfaces.BindingsInstallerHolder

/**
 * Bridge to the shared C++ SmoothClip registry. All driver state, animation and
 * geometry live in native C++ (see android/src/main/cpp); this object only loads
 * the library, exposes the worklet-callable JSI bindings installer, and forwards
 * Fabric view lifecycle to the registry.
 */
@DoNotStrip
internal object SmoothClipBindings {
    init {
        System.loadLibrary("smoothclipview")
    }

    /** Installs `global.__SmoothClipView` and wires completion delivery. */
    external fun getBindingsInstaller(): BindingsInstallerHolder

    external fun nativeRegisterView(
        driverId: Double,
        view: SmoothClipView,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        radius: Double,
        contentTranslateX: Double,
        contentTranslateY: Double,
        density: Double,
        widthPx: Double,
        heightPx: Double,
    )

    /**
     * Pushes a registered view's density and pixel host size so driver
     * deliveries are pre-normalized in C++; redelivers the visible value.
     */
    external fun nativeSetViewHostGeometry(
        driverId: Double,
        view: SmoothClipView,
        density: Double,
        widthPx: Double,
        heightPx: Double,
    )

    external fun nativeUnregisterView(driverId: Double, view: SmoothClipView)

    /**
     * Notifies the registry that a registered view attached to a window; a
     * latched animation may only start once a view can produce a visible
     * frame (attached and with real host geometry).
     */
    external fun nativeViewBecameDisplayable(driverId: Double, view: SmoothClipView)

    /**
     * Releases runtime-bound listener state during host teardown; must run
     * while the JS runtime is still alive (module invalidate).
     */
    external fun nativeInvalidate()
}
