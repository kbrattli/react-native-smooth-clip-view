package com.smoothclipview

import android.content.res.Configuration
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Region
import android.os.Build
import android.os.Trace
import android.view.MotionEvent
import android.view.View
import android.view.ViewOutlineProvider
import com.facebook.proguard.annotations.DoNotStrip
import com.facebook.react.uimanager.PixelUtil
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.views.view.ReactViewGroup
import kotlin.math.roundToInt
import kotlin.math.abs
import kotlin.math.pow

class SmoothClipView(context: ThemedReactContext) : ReactViewGroup(context) {
    private val clipContainer = ReactViewGroup(context)
    internal val contentContainer = ReactViewGroup(context)
    private var requestedX = 0f
    private var requestedY = 0f
    private var requestedWidth = 0f
    private var requestedHeight = 0f
    private var requestedTopLeftRadius = 0f
    private var requestedTopRightRadius = 0f
    private var requestedBottomRightRadius = 0f
    private var requestedBottomLeftRadius = 0f
    private var requestedCurveCode = CLIP_CURVE_CIRCULAR
    private var requestedContentTranslateX = 0f
    private var requestedContentTranslateY = 0f
    private var requestedContentScale = 1f
    private var requestedShadowEnabled = false
    private var requestedShadowRed = 0f
    private var requestedShadowGreen = 0f
    private var requestedShadowBlue = 0f
    private var requestedShadowAlpha = 1f
    private var requestedShadowOffsetX = 0f
    private var requestedShadowOffsetY = 0f
    private var requestedShadowBlurRadius = 0f
    private var requestedShadowSpreadDistance = 0f
    private var clipLeft = 0f
    private var clipTop = 0f
    private var clipRight = 0f
    private var clipBottom = 0f
    private var clipTopLeftRadius = 0f
    private var clipTopRightRadius = 0f
    private var clipBottomRightRadius = 0f
    private var clipBottomLeftRadius = 0f
    private var clipCurveCode = CLIP_CURVE_CIRCULAR
    private val clipPath = Path()
    private var boxShadowPath: Path? = null
    private var boxShadowPaint: Paint? = null
    private var clipIsEmpty = true
    private var requestedImportantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_AUTO
    private var acceptingTouchStream = false

    /** Driver this view is registered with in the native registry (0 = none). */
    internal var boundDriverId: Double = 0.0

    /** Set once a command arrives; later initial presentation props are ignored. */
    internal var commandIsAuthoritative = false

    private val clipOutlineProvider = object : ViewOutlineProvider() {
        override fun getOutline(view: View, outline: Outline) {
            if (clipIsEmpty) {
                outline.setEmpty()
                return
            }

            // Outline.setRoundRect only accepts integer edges. The raw path
            // keeps sub-pixel coordinates and off-host geometry intact.
            outline.setPath(clipPath)
        }
    }

    init {
        clipContainer.addView(contentContainer)
        super.addView(clipContainer)
        clipContainer.outlineProvider = clipOutlineProvider
        clipContainer.clipToOutline = true
        clipToOutline = false
        setWillNotDraw(false)
        visibility = INVISIBLE
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
    }

    /** DIP fallback used until a registered view has pushed host metrics. */
    @DoNotStrip
    fun setClipPresentationDip(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        topLeftRadius: Double,
        topRightRadius: Double,
        bottomRightRadius: Double,
        bottomLeftRadius: Double,
        curveCode: Int,
        contentTranslateX: Double,
        contentTranslateY: Double,
        contentScale: Double,
        shadowEnabled: Boolean = false,
        shadowRed: Double = 0.0,
        shadowGreen: Double = 0.0,
        shadowBlue: Double = 0.0,
        shadowAlpha: Double = 1.0,
        shadowOffsetX: Double = 0.0,
        shadowOffsetY: Double = 0.0,
        shadowBlurRadius: Double = 0.0,
        shadowSpreadDistance: Double = 0.0,
    ) {
        if (!x.isFinite() || !y.isFinite() || !width.isFinite() ||
            !height.isFinite() || !topLeftRadius.isFinite() ||
            !topRightRadius.isFinite() || !bottomRightRadius.isFinite() ||
            !bottomLeftRadius.isFinite() || !contentTranslateX.isFinite() ||
            !contentTranslateY.isFinite() || !contentScale.isFinite() ||
            !shadowRed.isFinite() || !shadowGreen.isFinite() ||
            !shadowBlue.isFinite() || !shadowAlpha.isFinite() ||
            !shadowOffsetX.isFinite() ||
            !shadowOffsetY.isFinite() || !shadowBlurRadius.isFinite() ||
            !shadowSpreadDistance.isFinite() || contentScale <= 0.0 ||
            shadowRed !in 0.0..1.0 || shadowGreen !in 0.0..1.0 ||
            shadowBlue !in 0.0..1.0 || shadowAlpha !in 0.0..1.0 ||
            shadowBlurRadius < 0.0 ||
            (curveCode != CLIP_CURVE_CIRCULAR && curveCode != CLIP_CURVE_CONTINUOUS)
        ) {
            return
        }

        val nextX = PixelUtil.toPixelFromDIP(x).toFloat()
        val nextY = PixelUtil.toPixelFromDIP(y).toFloat()
        val nextWidth = PixelUtil.toPixelFromDIP(width).toFloat()
        val nextHeight = PixelUtil.toPixelFromDIP(height).toFloat()
        val nextTopLeftRadius = PixelUtil.toPixelFromDIP(topLeftRadius).toFloat()
        val nextTopRightRadius = PixelUtil.toPixelFromDIP(topRightRadius).toFloat()
        val nextBottomRightRadius = PixelUtil.toPixelFromDIP(bottomRightRadius).toFloat()
        val nextBottomLeftRadius = PixelUtil.toPixelFromDIP(bottomLeftRadius).toFloat()
        val nextContentTranslateX = PixelUtil.toPixelFromDIP(contentTranslateX).toFloat()
        val nextContentTranslateY = PixelUtil.toPixelFromDIP(contentTranslateY).toFloat()
        val nextContentScale = contentScale.toFloat()
        val nextShadowOffsetX = PixelUtil.toPixelFromDIP(shadowOffsetX).toFloat()
        val nextShadowOffsetY = PixelUtil.toPixelFromDIP(shadowOffsetY).toFloat()
        val nextShadowBlurRadius = PixelUtil.toPixelFromDIP(shadowBlurRadius).toFloat()
        val nextShadowSpreadDistance =
            PixelUtil.toPixelFromDIP(shadowSpreadDistance).toFloat()
        if (!nextX.isFinite() || !nextY.isFinite() || !nextWidth.isFinite() ||
            !nextHeight.isFinite() || !nextTopLeftRadius.isFinite() ||
            !nextTopRightRadius.isFinite() || !nextBottomRightRadius.isFinite() ||
            !nextBottomLeftRadius.isFinite() || !nextContentTranslateX.isFinite() ||
            !nextContentTranslateY.isFinite() || !nextContentScale.isFinite() ||
            !nextShadowOffsetX.isFinite() || !nextShadowOffsetY.isFinite() ||
            !nextShadowBlurRadius.isFinite() ||
            !nextShadowSpreadDistance.isFinite() || nextContentScale <= 0f
        ) {
            return
        }

        requestedX = nextX
        requestedY = nextY
        requestedWidth = nextWidth
        requestedHeight = nextHeight
        requestedTopLeftRadius = nextTopLeftRadius
        requestedTopRightRadius = nextTopRightRadius
        requestedBottomRightRadius = nextBottomRightRadius
        requestedBottomLeftRadius = nextBottomLeftRadius
        requestedCurveCode = curveCode
        requestedContentTranslateX = nextContentTranslateX
        requestedContentTranslateY = nextContentTranslateY
        requestedContentScale = nextContentScale
        storeShadow(
            shadowEnabled,
            shadowRed.toFloat(),
            shadowGreen.toFloat(),
            shadowBlue.toFloat(),
            shadowAlpha.toFloat(),
            nextShadowOffsetX,
            nextShadowOffsetY,
            nextShadowBlurRadius,
            nextShadowSpreadDistance,
        )
        applyRequestedGeometry()
    }

    /** Driver hot path. Geometry is canonical, raw, and host-independent. */
    @DoNotStrip
    fun setClipPresentationPx(
        left: Float,
        top: Float,
        right: Float,
        bottom: Float,
        topLeftRadius: Float,
        topRightRadius: Float,
        bottomRightRadius: Float,
        bottomLeftRadius: Float,
        curveCode: Int,
        contentTranslateX: Float,
        contentTranslateY: Float,
        contentScale: Float,
        shadowEnabled: Boolean = false,
        shadowRed: Float = 0f,
        shadowGreen: Float = 0f,
        shadowBlue: Float = 0f,
        shadowAlpha: Float = 1f,
        shadowOffsetX: Float = 0f,
        shadowOffsetY: Float = 0f,
        shadowBlurRadius: Float = 0f,
        shadowSpreadDistance: Float = 0f,
    ) {
        if (!left.isFinite() || !top.isFinite() || !right.isFinite() ||
            !bottom.isFinite() || !topLeftRadius.isFinite() ||
            !topRightRadius.isFinite() || !bottomRightRadius.isFinite() ||
            !bottomLeftRadius.isFinite() || !contentTranslateX.isFinite() ||
            !contentTranslateY.isFinite() || !contentScale.isFinite() ||
            !shadowRed.isFinite() || !shadowGreen.isFinite() ||
            !shadowBlue.isFinite() || !shadowAlpha.isFinite() ||
            !shadowOffsetX.isFinite() ||
            !shadowOffsetY.isFinite() || !shadowBlurRadius.isFinite() ||
            !shadowSpreadDistance.isFinite() || contentScale <= 0f ||
            shadowRed !in 0f..1f || shadowGreen !in 0f..1f ||
            shadowBlue !in 0f..1f || shadowAlpha !in 0f..1f ||
            shadowBlurRadius < 0f ||
            (curveCode != CLIP_CURVE_CIRCULAR && curveCode != CLIP_CURVE_CONTINUOUS)
        ) {
            return
        }

        if (BuildConfig.DEBUG) Trace.beginSection("SmoothClip.applyPresentationPx")
        try {
            requestedContentTranslateX = contentTranslateX
            requestedContentTranslateY = contentTranslateY
            requestedContentScale = contentScale
            storeShadow(
                shadowEnabled,
                shadowRed,
                shadowGreen,
                shadowBlue,
                shadowAlpha,
                shadowOffsetX,
                shadowOffsetY,
                shadowBlurRadius,
                shadowSpreadDistance,
            )
            applyCanonicalClipPx(
                left,
                top,
                right,
                bottom,
                topLeftRadius,
                topRightRadius,
                bottomRightRadius,
                bottomLeftRadius,
                curveCode,
            )
        } finally {
            if (BuildConfig.DEBUG) Trace.endSection()
        }
    }

    private fun applyRequestedGeometry() {
        canonicalizeClipGeometryPx(
            requestedX,
            requestedY,
            requestedWidth,
            requestedHeight,
            requestedTopLeftRadius,
            requestedTopRightRadius,
            requestedBottomRightRadius,
            requestedBottomLeftRadius,
            requestedCurveCode,
        ) { left, top, right, bottom, topLeft, topRight, bottomRight, bottomLeft, curve ->
            applyCanonicalClipPx(
                left,
                top,
                right,
                bottom,
                topLeft,
                topRight,
                bottomRight,
                bottomLeft,
                curve,
            )
        }
    }

    private fun storeShadow(
        enabled: Boolean,
        red: Float,
        green: Float,
        blue: Float,
        alpha: Float,
        offsetX: Float,
        offsetY: Float,
        blurRadius: Float,
        spreadDistance: Float,
    ) {
        val wasVisible = requestedShadowEnabled && requestedShadowAlpha > 0f
        val isVisible = enabled && alpha > 0f
        val paintChanged = red != requestedShadowRed ||
            green != requestedShadowGreen || blue != requestedShadowBlue ||
            alpha != requestedShadowAlpha || blurRadius != requestedShadowBlurRadius
        val pathChanged = offsetX != requestedShadowOffsetX ||
            offsetY != requestedShadowOffsetY ||
            spreadDistance != requestedShadowSpreadDistance
        requestedShadowEnabled = enabled
        requestedShadowRed = red
        requestedShadowGreen = green
        requestedShadowBlue = blue
        requestedShadowAlpha = alpha
        requestedShadowOffsetX = offsetX
        requestedShadowOffsetY = offsetY
        requestedShadowBlurRadius = blurRadius
        requestedShadowSpreadDistance = spreadDistance
        if (!isVisible) {
            if (wasVisible) invalidate()
            return
        }
        if (paintChanged || boxShadowPaint == null) updateBoxShadowPaint()
        if (pathChanged || !wasVisible || boxShadowPath == null) {
            rebuildBoxShadowPath()
        }
        if (paintChanged || pathChanged || !wasVisible) invalidate()
    }

    private fun updateBoxShadowPaint() {
        val paint = boxShadowPaint ?: Paint(Paint.ANTI_ALIAS_FLAG).also {
            boxShadowPaint = it
        }
        paint.color = Color.argb(
            (requestedShadowAlpha * 255f).roundToInt(),
            (requestedShadowRed * 255f).roundToInt(),
            (requestedShadowGreen * 255f).roundToInt(),
            (requestedShadowBlue * 255f).roundToInt(),
        )
        val sigmaPx = requestedShadowBlurRadius * 0.5f
        val maskRadius = if (sigmaPx > 0.5f) {
            (sigmaPx - 0.5f) / 0.57735f
        } else {
            0f
        }
        paint.maskFilter = if (maskRadius > 0f) {
            BlurMaskFilter(maskRadius, BlurMaskFilter.Blur.NORMAL)
        } else {
            null
        }
    }

    private fun adjustedRadiusForSpread(radius: Float, spread: Float): Float {
        val magnitude = abs(spread)
        val multiplier = if (magnitude > 0f && radius < magnitude) {
            1f + (radius / magnitude - 1f).pow(3)
        } else {
            1f
        }
        return (radius + spread * multiplier).coerceAtLeast(0f)
    }

    private fun rebuildBoxShadowPath() {
        if (!requestedShadowEnabled || requestedShadowAlpha <= 0f) return
        val path = boxShadowPath ?: Path().also { boxShadowPath = it }
        path.reset()
        if (clipIsEmpty) return
        val spread = requestedShadowSpreadDistance
        val left = clipLeft - spread + requestedShadowOffsetX
        val top = clipTop - spread + requestedShadowOffsetY
        val right = clipRight + spread + requestedShadowOffsetX
        val bottom = clipBottom + spread + requestedShadowOffsetY
        if (right <= left || bottom <= top) return
        appendRoundedRectPath(
            path,
            left,
            top,
            right,
            bottom,
            adjustedRadiusForSpread(clipTopLeftRadius, spread),
            adjustedRadiusForSpread(clipTopRightRadius, spread),
            adjustedRadiusForSpread(clipBottomRightRadius, spread),
            adjustedRadiusForSpread(clipBottomLeftRadius, spread),
            clipCurveCode,
        )
    }

    override fun dispatchDraw(canvas: Canvas) {
        val hostSaveCount = canvas.save()
        canvas.clipRect(0f, 0f, width.toFloat(), height.toFloat())
        try {
            val shadowPath = boxShadowPath
            val shadowPaint = boxShadowPaint
            if (requestedShadowEnabled && !clipIsEmpty &&
                requestedShadowAlpha > 0f && shadowPath != null &&
                shadowPaint != null && !shadowPath.isEmpty
            ) {
                val apertureSaveCount = canvas.save()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    canvas.clipOutPath(clipPath)
                } else {
                    @Suppress("DEPRECATION")
                    canvas.clipPath(clipPath, Region.Op.DIFFERENCE)
                }
                canvas.drawPath(shadowPath, shadowPaint)
                canvas.restoreToCount(apertureSaveCount)
            }
            super.dispatchDraw(canvas)
        } finally {
            canvas.restoreToCount(hostSaveCount)
        }
    }

    private fun applyCanonicalClipPx(
        left: Float,
        top: Float,
        right: Float,
        bottom: Float,
        topLeftRadius: Float,
        topRightRadius: Float,
        bottomRightRadius: Float,
        bottomLeftRadius: Float,
        curveCode: Int,
    ) {
        val isEmpty = right <= left || bottom <= top
        val geometryChanged = left != clipLeft || top != clipTop ||
            right != clipRight ||
            bottom != clipBottom || topLeftRadius != clipTopLeftRadius ||
            topRightRadius != clipTopRightRadius ||
            bottomRightRadius != clipBottomRightRadius ||
            bottomLeftRadius != clipBottomLeftRadius || curveCode != clipCurveCode

        clipLeft = left
        clipTop = top
        clipRight = right
        clipBottom = bottom
        val radiiAreUniform = topLeftRadius == topRightRadius &&
            topLeftRadius == bottomRightRadius &&
            topLeftRadius == bottomLeftRadius
        clipTopLeftRadius = topLeftRadius
        clipTopRightRadius = topRightRadius
        clipBottomRightRadius = bottomRightRadius
        clipBottomLeftRadius = bottomLeftRadius
        clipCurveCode = curveCode
        applyContentTransform()

        clipIsEmpty = isEmpty
        reapplyClipPresentation()

        if (!geometryChanged) return

        clipPath.reset()
        if (!isEmpty) {
            if (curveCode == CLIP_CURVE_CIRCULAR && radiiAreUniform) {
                clipPath.addRoundRect(
                    left,
                    top,
                    right,
                    bottom,
                    topLeftRadius,
                    topLeftRadius,
                    Path.Direction.CW,
                )
            } else {
                appendRoundedRectPath(
                    clipPath,
                    left,
                    top,
                    right,
                    bottom,
                    topLeftRadius,
                    topRightRadius,
                    bottomRightRadius,
                    bottomLeftRadius,
                    curveCode,
                )
            }
        }
        rebuildBoxShadowPath()
        clipContainer.invalidateOutline()
        if (requestedShadowEnabled) invalidate()
    }

    private fun applyContentTransform() {
        contentContainer.translationX = requestedContentTranslateX
        contentContainer.translationY = requestedContentTranslateY
        // Scale is intentionally centered and lives on the content only. View
        // translation properties are applied independently of scale, so a
        // caller's tx/ty remains a physical-pixel offset rather than scaling
        // around the origin with the content.
        contentContainer.pivotX = contentContainer.width / 2f
        contentContainer.pivotY = contentContainer.height / 2f
        contentContainer.scaleX = requestedContentScale
        contentContainer.scaleY = requestedContentScale
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        clipContainer.layout(0, 0, w, h)
        contentContainer.layout(0, 0, w, h)
        applyContentTransform()
        if (boundDriverId != 0.0) {
            // Host metrics only gate lifecycle readiness. Redelivery remains
            // raw and canonical; this view owns the final viewport crop.
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
        reapplyClipPresentation()
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        pushLifecycleVisibility()
    }

    override fun onDetachedFromWindow() {
        if (boundDriverId != 0.0) {
            SmoothClipBindings.nativeSetViewLifecycleVisibility(
                boundDriverId,
                this,
                false,
            )
        }
        clearTouchState()
        super.onDetachedFromWindow()
    }

    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        pushLifecycleVisibility()
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

    internal fun isHostLifecycleVisible(): Boolean =
        isAttachedToWindow && windowVisibility == VISIBLE

    private fun pushLifecycleVisibility() {
        if (boundDriverId == 0.0) return
        SmoothClipBindings.nativeSetViewLifecycleVisibility(
            boundDriverId,
            this,
            isHostLifecycleVisible(),
        )
    }

    private fun containsRoundedPoint(x: Float, y: Float): Boolean {
        // Reuse the exact path supplied to the Outline. Hit testing therefore
        // follows the rendered aperture, including continuous corners.
        return !clipIsEmpty && containsPathPoint(clipPath, x, y)
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        val action = event.actionMasked
        if (action == MotionEvent.ACTION_DOWN) {
            // The aperture gates admission only. Once accepted, the stream
            // belongs to Android until its real UP or CANCEL arrives.
            clearTouchState()
            if (!containsRoundedPoint(event.x, event.y)) return false
            acceptingTouchStream = true
        }

        if (!acceptingTouchStream) return false
        val result = super.dispatchTouchEvent(event)
        if ((action == MotionEvent.ACTION_DOWN && !result) ||
            action == MotionEvent.ACTION_CANCEL || action == MotionEvent.ACTION_UP
        ) {
            clearTouchState()
        }
        return result
    }

    private fun clearTouchState() {
        acceptingTouchStream = false
    }

    fun setRequestedImportantForAccessibility(value: Int) {
        requestedImportantForAccessibility = value
        reapplyClipPresentation()
    }

    fun reapplyClipPresentation() {
        val apertureVisible = apertureIntersectsHost()
        val expectedVisibility = renderVisibility(
            apertureVisible || shadowIntersectsHost(),
        )
        if (visibility != expectedVisibility) {
            visibility = expectedVisibility
        }

        val expectedAccessibility = clipAccessibility(
            !apertureVisible,
            requestedImportantForAccessibility,
        )
        if (importantForAccessibility != expectedAccessibility) {
            importantForAccessibility = expectedAccessibility
        }
    }

    private fun apertureIntersectsHost(): Boolean =
        !clipIsEmpty && clipRight > 0f && clipBottom > 0f &&
            clipLeft < width.toFloat() && clipTop < height.toFloat()

    private fun shadowIntersectsHost(): Boolean {
        if (clipIsEmpty || !requestedShadowEnabled || requestedShadowAlpha <= 0f) {
            return false
        }
        val spread = requestedShadowSpreadDistance
        val pathLeft = clipLeft - spread + requestedShadowOffsetX
        val pathTop = clipTop - spread + requestedShadowOffsetY
        val pathRight = clipRight + spread + requestedShadowOffsetX
        val pathBottom = clipBottom + spread + requestedShadowOffsetY
        if (pathRight <= pathLeft || pathBottom <= pathTop) return false

        // CSS blur is specified as a diameter-like radius. Expanding by the
        // full value is conservative and prevents culling a faint blur tail.
        val blurOutset = requestedShadowBlurRadius
        return pathRight + blurOutset > 0f && pathBottom + blurOutset > 0f &&
            pathLeft - blurOutset < width.toFloat() &&
            pathTop - blurOutset < height.toFloat()
    }

    fun resetClipState() {
        clearTouchState()
        commandIsAuthoritative = false
        requestedX = 0f
        requestedY = 0f
        requestedWidth = 0f
        requestedHeight = 0f
        requestedTopLeftRadius = 0f
        requestedTopRightRadius = 0f
        requestedBottomRightRadius = 0f
        requestedBottomLeftRadius = 0f
        requestedCurveCode = CLIP_CURVE_CIRCULAR
        requestedContentTranslateX = 0f
        requestedContentTranslateY = 0f
        requestedContentScale = 1f
        requestedShadowEnabled = false
        requestedShadowRed = 0f
        requestedShadowGreen = 0f
        requestedShadowBlue = 0f
        requestedShadowAlpha = 1f
        requestedShadowOffsetX = 0f
        requestedShadowOffsetY = 0f
        requestedShadowBlurRadius = 0f
        requestedShadowSpreadDistance = 0f
        boxShadowPaint = null
        boxShadowPath = null
        applyContentTransform()
        clipPath.reset()
        requestedImportantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_AUTO
        applyRequestedGeometry()
    }
}
