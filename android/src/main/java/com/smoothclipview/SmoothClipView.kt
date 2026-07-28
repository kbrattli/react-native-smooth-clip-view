package com.smoothclipview

import android.content.res.Configuration
import android.graphics.Outline
import android.view.MotionEvent
import android.view.View
import android.view.ViewOutlineProvider
import com.facebook.proguard.annotations.DoNotStrip
import com.facebook.react.uimanager.PixelUtil
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.views.view.ReactViewGroup
import kotlin.math.roundToInt

class SmoothClipView(context: ThemedReactContext) : ReactViewGroup(context) {
    internal val contentContainer = ReactViewGroup(context)
    private var requestedX = 0f
    private var requestedY = 0f
    private var requestedWidth = 0f
    private var requestedHeight = 0f
    private var requestedRadius = 0f
    private var requestedContentTranslateX = 0f
    private var requestedContentTranslateY = 0f
    private var clipLeft = 0f
    private var clipTop = 0f
    private var clipRight = 0f
    private var clipBottom = 0f
    private var clipRadius = 0f
    // Rounded edges actually emitted to the outline provider. Sub-pixel changes
    // that round to the same integers must not invalidate the outline.
    private var outlineLeft = 0
    private var outlineTop = 0
    private var outlineRight = 0
    private var outlineBottom = 0
    private var clipIsEmpty = true
    private var requestedImportantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_AUTO
    private var acceptingTouchStream = false

    /** Driver this view is registered with in the native registry (0 = none). */
    internal var boundDriverId: Double = 0.0

    /** Set once a legacy command arrives; later initialClip* props are ignored. */
    internal var commandIsAuthoritative = false

    private val clipOutlineProvider = object : ViewOutlineProvider() {
        override fun getOutline(view: View, outline: Outline) {
            if (clipIsEmpty) {
                outline.setEmpty()
                return
            }

            outline.setRoundRect(
                outlineLeft,
                outlineTop,
                outlineRight,
                outlineBottom,
                clipRadius,
            )
        }
    }

    init {
        super.addView(contentContainer)
        outlineProvider = clipOutlineProvider
        clipToOutline = true
        visibility = INVISIBLE
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
    }

    fun setClipGeometryDip(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        radius: Double,
    ) = setClipPresentationDip(x, y, width, height, radius, 0.0, 0.0)

    @DoNotStrip
    fun setClipPresentationDip(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        radius: Double,
        contentTranslateX: Double,
        contentTranslateY: Double,
    ) {
        if (!x.isFinite() || !y.isFinite() || !width.isFinite() ||
            !height.isFinite() || !radius.isFinite() ||
            !contentTranslateX.isFinite() || !contentTranslateY.isFinite()
        ) {
            return
        }

        val nextX = PixelUtil.toPixelFromDIP(x).toFloat()
        val nextY = PixelUtil.toPixelFromDIP(y).toFloat()
        val nextWidth = PixelUtil.toPixelFromDIP(width).toFloat()
        val nextHeight = PixelUtil.toPixelFromDIP(height).toFloat()
        val nextRadius = PixelUtil.toPixelFromDIP(radius).toFloat()
        val nextContentTranslateX = PixelUtil.toPixelFromDIP(contentTranslateX).toFloat()
        val nextContentTranslateY = PixelUtil.toPixelFromDIP(contentTranslateY).toFloat()
        if (!nextX.isFinite() || !nextY.isFinite() || !nextWidth.isFinite() ||
            !nextHeight.isFinite() || !nextRadius.isFinite() ||
            !nextContentTranslateX.isFinite() || !nextContentTranslateY.isFinite()
        ) {
            return
        }

        requestedX = nextX
        requestedY = nextY
        requestedWidth = nextWidth
        requestedHeight = nextHeight
        requestedRadius = nextRadius
        if (requestedContentTranslateX != nextContentTranslateX) {
            requestedContentTranslateX = nextContentTranslateX
            contentContainer.translationX = nextContentTranslateX
        }
        if (requestedContentTranslateY != nextContentTranslateY) {
            requestedContentTranslateY = nextContentTranslateY
            contentContainer.translationY = nextContentTranslateY
        }
        applyRequestedGeometry()
    }

    /**
     * Driver hot path: called from the C++ registry with final pixel-space,
     * pre-normalized values (see deliverToView in SmoothClipRegistry.cpp).
     * No validation, scaling or normalization happens here.
     */
    @DoNotStrip
    fun setClipPresentationPx(
        left: Float,
        top: Float,
        right: Float,
        bottom: Float,
        radius: Float,
        contentTranslateX: Float,
        contentTranslateY: Float,
    ) {
        if (requestedContentTranslateX != contentTranslateX) {
            requestedContentTranslateX = contentTranslateX
            contentContainer.translationX = contentTranslateX
        }
        if (requestedContentTranslateY != contentTranslateY) {
            requestedContentTranslateY = contentTranslateY
            contentContainer.translationY = contentTranslateY
        }
        applyNormalizedClipPx(left, top, right, bottom, radius)
    }

    private fun applyRequestedGeometry() {
        normalizeClipGeometryPx(
            requestedX,
            requestedY,
            requestedWidth,
            requestedHeight,
            requestedRadius,
            width.toFloat(),
            height.toFloat(),
        ) { left, top, right, bottom, radius ->
            applyNormalizedClipPx(left, top, right, bottom, radius)
        }
    }

    private fun applyNormalizedClipPx(
        left: Float,
        top: Float,
        right: Float,
        bottom: Float,
        radius: Float,
    ) {
        val isEmpty = right <= left || bottom <= top
        val outlineGeometryChanged = outlineChanged(
            left,
            top,
            right,
            bottom,
            radius,
            outlineLeft,
            outlineTop,
            outlineRight,
            outlineBottom,
            clipRadius,
        )

        if (!outlineGeometryChanged && isEmpty == clipIsEmpty) {
            return
        }

        clipLeft = left
        clipTop = top
        clipRight = right
        clipBottom = bottom
        clipRadius = radius
        outlineLeft = left.roundToInt()
        outlineTop = top.roundToInt()
        outlineRight = right.roundToInt()
        outlineBottom = bottom.roundToInt()

        if (isEmpty != clipIsEmpty) {
            clipIsEmpty = isEmpty
            visibility = clipVisibility(isEmpty)
            importantForAccessibility = clipAccessibility(
                isEmpty,
                requestedImportantForAccessibility,
            )
            if (isEmpty) acceptingTouchStream = false
        }

        invalidateOutline()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        contentContainer.layout(0, 0, w, h)
        if (boundDriverId != 0.0) {
            // Driver deliveries are pre-normalized in C++ against the pushed
            // host metrics; refresh them and let the registry redeliver the
            // visible value synchronously.
            SmoothClipBindings.nativeSetViewHostGeometry(
                boundDriverId,
                this,
                densityScale(),
                w.toDouble(),
                h.toDouble(),
            )
        }
        if (boundDriverId == 0.0 || commandIsAuthoritative) {
            // Command geometry lives in the requested* DIP fields. Reapplying
            // after the driver redelivery keeps the last-writer semantics: an
            // authoritative command wins over the driver value on resize.
            applyRequestedGeometry()
        }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        if (boundDriverId != 0.0) {
            // A latched animation may only start once this view can produce a
            // visible frame; window attach is that signal for views that
            // registered from a detached subtree.
            SmoothClipBindings.nativeViewBecameDisplayable(boundDriverId, this)
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (boundDriverId != 0.0) {
            // Density can change without a size change (display switch); the
            // registry scales DIP deliveries by the pushed density.
            SmoothClipBindings.nativeSetViewHostGeometry(
                boundDriverId,
                this,
                densityScale(),
                width.toDouble(),
                height.toDouble(),
            )
        }
    }

    internal fun densityScale(): Double = PixelUtil.toPixelFromDIP(1f).toDouble()

    private fun containsRoundedPoint(x: Float, y: Float): Boolean {
        return containsRoundedPointPx(
            x,
            y,
            clipLeft,
            clipTop,
            clipRight,
            clipBottom,
            clipRadius,
            clipIsEmpty,
        )
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                acceptingTouchStream = containsRoundedPoint(event.x, event.y)
                if (!acceptingTouchStream) return false
            }
            MotionEvent.ACTION_CANCEL, MotionEvent.ACTION_UP -> {
                val result = if (acceptingTouchStream) {
                    super.dispatchTouchEvent(event)
                } else {
                    false
                }
                acceptingTouchStream = false
                return result
            }
        }

        return acceptingTouchStream && super.dispatchTouchEvent(event)
    }

    fun setRequestedImportantForAccessibility(value: Int) {
        requestedImportantForAccessibility = value
        reapplyClipPresentation()
    }

    fun reapplyClipPresentation() {
        val expectedVisibility = clipVisibility(clipIsEmpty)
        if (visibility != expectedVisibility) {
            visibility = expectedVisibility
        }

        val expectedAccessibility = clipAccessibility(
            clipIsEmpty,
            requestedImportantForAccessibility,
        )
        if (importantForAccessibility != expectedAccessibility) {
            importantForAccessibility = expectedAccessibility
        }
    }

    fun resetClipState() {
        acceptingTouchStream = false
        commandIsAuthoritative = false
        requestedX = 0f
        requestedY = 0f
        requestedWidth = 0f
        requestedHeight = 0f
        requestedRadius = 0f
        requestedContentTranslateX = 0f
        requestedContentTranslateY = 0f
        contentContainer.translationX = 0f
        contentContainer.translationY = 0f
        outlineLeft = 0
        outlineTop = 0
        outlineRight = 0
        outlineBottom = 0
        requestedImportantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_AUTO
        applyRequestedGeometry()
    }
}
