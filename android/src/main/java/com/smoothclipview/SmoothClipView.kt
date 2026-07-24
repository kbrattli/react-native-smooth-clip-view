package com.smoothclipview

import android.graphics.Outline
import android.view.MotionEvent
import android.view.View
import android.view.ViewOutlineProvider
import com.facebook.react.uimanager.PixelUtil
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.views.view.ReactViewGroup
import kotlin.math.roundToInt

class SmoothClipView(context: ThemedReactContext) : ReactViewGroup(context) {
    private var requestedX = 0f
    private var requestedY = 0f
    private var requestedWidth = 0f
    private var requestedHeight = 0f
    private var requestedRadius = 0f
    private var clipLeft = 0f
    private var clipTop = 0f
    private var clipRight = 0f
    private var clipBottom = 0f
    private var clipRadius = 0f
    private var clipIsEmpty = true
    private var requestedImportantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_AUTO
    private var acceptingTouchStream = false

    private val clipOutlineProvider = object : ViewOutlineProvider() {
        override fun getOutline(view: View, outline: Outline) {
            if (clipIsEmpty) {
                outline.setEmpty()
                return
            }

            outline.setRoundRect(
                clipLeft.roundToInt(),
                clipTop.roundToInt(),
                clipRight.roundToInt(),
                clipBottom.roundToInt(),
                clipRadius,
            )
        }
    }

    init {
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
    ) {
        if (!x.isFinite() || !y.isFinite() || !width.isFinite() ||
            !height.isFinite() || !radius.isFinite()
        ) {
            return
        }

        val nextX = PixelUtil.toPixelFromDIP(x).toFloat()
        val nextY = PixelUtil.toPixelFromDIP(y).toFloat()
        val nextWidth = PixelUtil.toPixelFromDIP(width).toFloat()
        val nextHeight = PixelUtil.toPixelFromDIP(height).toFloat()
        val nextRadius = PixelUtil.toPixelFromDIP(radius).toFloat()
        if (!nextX.isFinite() || !nextY.isFinite() || !nextWidth.isFinite() ||
            !nextHeight.isFinite() || !nextRadius.isFinite()
        ) {
            return
        }

        requestedX = nextX
        requestedY = nextY
        requestedWidth = nextWidth
        requestedHeight = nextHeight
        requestedRadius = nextRadius
        applyRequestedGeometry()
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
            val isEmpty = right <= left || bottom <= top
            val geometryChanged =
                left != clipLeft || top != clipTop || right != clipRight ||
                    bottom != clipBottom || radius != clipRadius

            if (!geometryChanged && isEmpty == clipIsEmpty) {
                return@normalizeClipGeometryPx
            }

            clipLeft = left
            clipTop = top
            clipRight = right
            clipBottom = bottom
            clipRadius = radius

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
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        applyRequestedGeometry()
    }

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
        requestedX = 0f
        requestedY = 0f
        requestedWidth = 0f
        requestedHeight = 0f
        requestedRadius = 0f
        requestedImportantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_AUTO
        applyRequestedGeometry()
    }
}
