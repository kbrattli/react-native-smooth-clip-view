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

    override fun getPresentationProtocolVersion(): Double = 2.0

    // Static complex paths are supported, but autonomous animation remains a
    // measured capability. Keep it disabled until the physical-device path
    // sampling and frame-time gates are run for this release.
    override fun supportsAutonomousComplexPathAnimation(): Boolean = false

    override fun beginGroupInteractionV2(driverIds: ReadableArray): WritableArray =
        Arguments.createArray()

    override fun snapshotGroupV2(driverIds: ReadableArray): WritableArray =
        Arguments.createArray()

    override fun setClipPresentationBatchV2(entries: ReadableArray): Boolean = false

    override fun animateTimingGroupV2(
        controllerId: Double,
        entries: ReadableArray,
        durationMs: Double,
        controlPoint1X: Double,
        controlPoint1Y: Double,
        controlPoint2X: Double,
        controlPoint2Y: Double,
        reduceMotion: Double,
        suspensionPolicy: Double,
    ): Double = 0.0

    override fun animateSpringGroupV2(
        controllerId: Double,
        entries: ReadableArray,
        mass: Double,
        stiffness: Double,
        damping: Double,
        initialVelocity: Double,
        inheritVelocity: Boolean,
        reduceMotion: Double,
        suspensionPolicy: Double,
    ): Double = 0.0

    override fun animateKeyframesGroupV2(
        controllerId: Double,
        entries: ReadableArray,
        durationMs: Double,
        reduceMotion: Double,
        suspensionPolicy: Double,
    ): Double = 0.0

    override fun cancelAnimationGroupV2(
        groupId: Double,
        behavior: Double,
    ): WritableArray = Arguments.createArray()

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
        overridePendingAnimation: Boolean,
    ) = Unit

    override fun setClipPresentationV2(
        driverId: Double,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        topLeftRadius: Double,
        topRightRadius: Double,
        bottomRightRadius: Double,
        bottomLeftRadius: Double,
        curveCode: Double,
        contentTranslateX: Double,
        contentTranslateY: Double,
        contentScale: Double,
        takeOwnership: Boolean,
        overridePendingAnimation: Boolean,
    ) = Unit

    override fun beginInteraction(driverId: Double): WritableArray =
        Arguments.createArray()

    override fun beginInteractionV2(driverId: Double): WritableArray =
        Arguments.createArray()

    override fun snapshotCurrentV2(driverId: Double): WritableArray =
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

    override fun animateTimingV2(
        driverId: Double,
        hasInteractiveStart: Boolean,
        startX: Double,
        startY: Double,
        startWidth: Double,
        startHeight: Double,
        startTopLeftRadius: Double,
        startTopRightRadius: Double,
        startBottomRightRadius: Double,
        startBottomLeftRadius: Double,
        startCurveCode: Double,
        startContentTranslateX: Double,
        startContentTranslateY: Double,
        startContentScale: Double,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        topLeftRadius: Double,
        topRightRadius: Double,
        bottomRightRadius: Double,
        bottomLeftRadius: Double,
        curveCode: Double,
        contentTranslateX: Double,
        contentTranslateY: Double,
        contentScale: Double,
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

    override fun animateSpringV2(
        driverId: Double,
        hasInteractiveStart: Boolean,
        startX: Double,
        startY: Double,
        startWidth: Double,
        startHeight: Double,
        startTopLeftRadius: Double,
        startTopRightRadius: Double,
        startBottomRightRadius: Double,
        startBottomLeftRadius: Double,
        startCurveCode: Double,
        startContentTranslateX: Double,
        startContentTranslateY: Double,
        startContentScale: Double,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        topLeftRadius: Double,
        topRightRadius: Double,
        bottomRightRadius: Double,
        bottomLeftRadius: Double,
        curveCode: Double,
        contentTranslateX: Double,
        contentTranslateY: Double,
        contentScale: Double,
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

    override fun animateKeyframesV2(
        driverId: Double,
        hasInteractiveStart: Boolean,
        startX: Double,
        startY: Double,
        startWidth: Double,
        startHeight: Double,
        startTopLeftRadius: Double,
        startTopRightRadius: Double,
        startBottomRightRadius: Double,
        startBottomLeftRadius: Double,
        startCurveCode: Double,
        startContentTranslateX: Double,
        startContentTranslateY: Double,
        startContentScale: Double,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        topLeftRadius: Double,
        topRightRadius: Double,
        bottomRightRadius: Double,
        bottomLeftRadius: Double,
        curveCode: Double,
        contentTranslateX: Double,
        contentTranslateY: Double,
        contentScale: Double,
        durationMs: Double,
        frames: ReadableArray,
        reduceMotion: Double,
    ): Double = 0.0

    override fun animateTimingFromV2(
        driverId: Double,
        startX: Double,
        startY: Double,
        startWidth: Double,
        startHeight: Double,
        startTopLeftRadius: Double,
        startTopRightRadius: Double,
        startBottomRightRadius: Double,
        startBottomLeftRadius: Double,
        startCurveCode: Double,
        startContentTranslateX: Double,
        startContentTranslateY: Double,
        startContentScale: Double,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        topLeftRadius: Double,
        topRightRadius: Double,
        bottomRightRadius: Double,
        bottomLeftRadius: Double,
        curveCode: Double,
        contentTranslateX: Double,
        contentTranslateY: Double,
        contentScale: Double,
        durationMs: Double,
        controlPoint1X: Double,
        controlPoint1Y: Double,
        controlPoint2X: Double,
        controlPoint2Y: Double,
        reduceMotion: Double,
    ): Double = 0.0

    override fun animateSpringFromV2(
        driverId: Double,
        startX: Double,
        startY: Double,
        startWidth: Double,
        startHeight: Double,
        startTopLeftRadius: Double,
        startTopRightRadius: Double,
        startBottomRightRadius: Double,
        startBottomLeftRadius: Double,
        startCurveCode: Double,
        startContentTranslateX: Double,
        startContentTranslateY: Double,
        startContentScale: Double,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        topLeftRadius: Double,
        topRightRadius: Double,
        bottomRightRadius: Double,
        bottomLeftRadius: Double,
        curveCode: Double,
        contentTranslateX: Double,
        contentTranslateY: Double,
        contentScale: Double,
        mass: Double,
        stiffness: Double,
        damping: Double,
        initialVelocity: Double,
        inheritVelocity: Boolean,
        reduceMotion: Double,
    ): Double = 0.0

    override fun animateKeyframesFromV2(
        driverId: Double,
        startX: Double,
        startY: Double,
        startWidth: Double,
        startHeight: Double,
        startTopLeftRadius: Double,
        startTopRightRadius: Double,
        startBottomRightRadius: Double,
        startBottomLeftRadius: Double,
        startCurveCode: Double,
        startContentTranslateX: Double,
        startContentTranslateY: Double,
        startContentScale: Double,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        topLeftRadius: Double,
        topRightRadius: Double,
        bottomRightRadius: Double,
        bottomLeftRadius: Double,
        curveCode: Double,
        contentTranslateX: Double,
        contentTranslateY: Double,
        contentScale: Double,
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

    override fun cancelAnimationV2(
        driverId: Double,
        animationId: Double,
        behavior: Double,
    ): WritableArray = Arguments.createArray()

    override fun destroyDriver(driverId: Double) = Unit
}
