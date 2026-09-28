package com.smoothclipview

import android.content.res.Configuration
import com.facebook.proguard.annotations.DoNotStrip
import com.facebook.react.uimanager.PixelUtil
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.views.view.ReactViewGroup

/**
 * A view translated by its controller's backdrop channel. The registry
 * delivers the channel in pixels on every clip delivery — a `setFrame`, a
 * run's frame, a run's end — inside the same Choreographer pass as the clip,
 * so the content never lands a frame after the aperture. The translation goes
 * on an inner container, leaving this view's own transform to React Native.
 */
class SmoothClipBackdropView(context: ThemedReactContext) : ReactViewGroup(context) {
    internal val contentContainer = ReactViewGroup(context)

    /** Driver this view is bound to in the native registry (0 = none). */
    internal var boundDriverId: Double = 0.0

    init {
        clipChildren = false
        super.addView(contentContainer)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        contentContainer.layout(0, 0, w, h)
    }

    /** Registry hot path: the backdrop translation, in pixels. */
    @DoNotStrip
    fun setBackdropTranslationPx(translateX: Float, translateY: Float) {
        contentContainer.translationX = translateX
        contentContainer.translationY = translateY
    }

    internal fun bindDriver(driverId: Double) {
        if (boundDriverId != 0.0 && boundDriverId != driverId) {
            SmoothClipBindings.nativeUnregisterBackdropView(boundDriverId, this)
        }
        boundDriverId = driverId
        if (driverId != 0.0) {
            SmoothClipBindings.nativeRegisterBackdropView(driverId, this, densityScale())
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // Density can change without a remount (display switch); the registry
        // scales the channel by the pushed density.
        if (boundDriverId != 0.0) {
            SmoothClipBindings.nativeRegisterBackdropView(boundDriverId, this, densityScale())
        }
    }

    private fun densityScale(): Double = PixelUtil.toPixelFromDIP(1f).toDouble()
}
