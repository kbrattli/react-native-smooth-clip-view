package com.smoothclipview

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.WritableArray
import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.turbomodule.core.interfaces.BindingsInstallerHolder
import com.facebook.react.turbomodule.core.interfaces.TurboModuleWithJSIBindings

/**
 * The Android driver runs entirely through worklet-callable C++ JSI bindings
 * (installed via [getBindingsInstaller]); JS resolves `global.__SmoothClipView`
 * instead of these TurboModule methods. The spec methods below are required by
 * codegen but are never invoked on Android.
 */
@ReactModule(name = NativeSmoothClipModuleSpec.NAME)
class SmoothClipModule(context: ReactApplicationContext) :
    NativeSmoothClipModuleSpec(context), TurboModuleWithJSIBindings {

    override fun getBindingsInstaller(): BindingsInstallerHolder =
        SmoothClipBindings.getBindingsInstaller()

    override fun invalidate() {
        super.invalidate()
        // Completions must stop and runtime-bound listener functions must be
        // released before the JS runtime is torn down; otherwise a later host
        // would deliver completions into a destroyed runtime.
        SmoothClipBindings.nativeInvalidate()
    }

    override fun setClipPresentation(
        driverId: Double,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        radius: Double,
        contentTranslateX: Double,
        contentTranslateY: Double,
        takeOwnership: Boolean,
    ) = Unit

    override fun beginInteraction(driverId: Double): WritableArray =
        Arguments.createArray()

    override fun animateTiming(
        driverId: Double,
        hasInteractiveStart: Boolean,
        startX: Double,
        startY: Double,
        startWidth: Double,
        startHeight: Double,
        startRadius: Double,
        startContentTranslateX: Double,
        startContentTranslateY: Double,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        radius: Double,
        contentTranslateX: Double,
        contentTranslateY: Double,
        durationMs: Double,
        controlPoint1X: Double,
        controlPoint1Y: Double,
        controlPoint2X: Double,
        controlPoint2Y: Double,
        reduceMotion: Double,
    ): Double = 0.0

    override fun animateSpring(
        driverId: Double,
        hasInteractiveStart: Boolean,
        startX: Double,
        startY: Double,
        startWidth: Double,
        startHeight: Double,
        startRadius: Double,
        startContentTranslateX: Double,
        startContentTranslateY: Double,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        radius: Double,
        contentTranslateX: Double,
        contentTranslateY: Double,
        mass: Double,
        stiffness: Double,
        damping: Double,
        initialVelocity: Double,
        inheritVelocity: Boolean,
        reduceMotion: Double,
    ): Double = 0.0

    override fun animateKeyframes(
        driverId: Double,
        hasInteractiveStart: Boolean,
        startX: Double,
        startY: Double,
        startWidth: Double,
        startHeight: Double,
        startRadius: Double,
        startContentTranslateX: Double,
        startContentTranslateY: Double,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        radius: Double,
        contentTranslateX: Double,
        contentTranslateY: Double,
        durationMs: Double,
        frames: ReadableArray,
        reduceMotion: Double,
    ): Double = 0.0

    override fun rejectAnimation(driverId: Double): Double = 0.0

    override fun cancelAnimation(
        driverId: Double,
        animationId: Double,
        behavior: Double,
    ): WritableArray = Arguments.createArray()

    override fun destroyDriver(driverId: Double) = Unit
}
