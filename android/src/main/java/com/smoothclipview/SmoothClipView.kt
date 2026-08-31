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
    private var clipRadius = 0f
    private var clipTopLeftRadius = 0f
    private var clipTopRightRadius = 0f
    private var clipBottomRightRadius = 0f
    private var clipBottomLeftRadius = 0f
    private var clipCurveCode = CLIP_CURVE_CIRCULAR
    private val clipPath = Path()
    private var boxShadowPath: Path? = null
    private var boxShadowPaint: Paint? = null
    private var outlineUsesPath = false
    private var outlineUsesFloatRoundRect = false
    // Rounded edges actually emitted to the outline provider. Sub-pixel changes
    // that round to the same integers must not invalidate the outline.
    private var outlineLeft = 0
    private var outlineTop = 0
    private var outlineRight = 0
    private var outlineBottom = 0
    private var clipIsEmpty = true
    // Sub-pixel remainder of the clip origin, carried on this view's own
    // translation and subtracted back out of the content container.
    private var clipResidualX = 0f
    private var clipResidualY = 0f
    // The consumer's `transform` translation, kept apart from the residual so
    // the two compose instead of clobbering each other.
    private var userTranslationX = 0f
    private var userTranslationY = 0f
    private var requestedImportantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_AUTO
    private var acceptingTouchStream = false
    private var retainedTouchEvent: MotionEvent? = null

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

            if (outlineUsesPath) {
                outline.setPath(clipPath)
            } else if (outlineUsesFloatRoundRect) {
                // Android's public Outline.setRoundRect overload accepts only
                // integer edges. Path.addRoundRect is the platform float
                // round-rect primitive; Outline.setPath preserves those edges
                // without snapping fractional edges to integer outline bounds.
                outline.setPath(clipPath)
            } else {
                outline.setRoundRect(
                    outlineLeft,
                    outlineTop,
                    outlineRight,
                    outlineBottom,
                    clipRadius,
                )
            }
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

    /**
     * Driver hot path. Geometry is already intersected with the host and
     * its four radii have already had the CSS overlap factor applied in C++.
     */
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
            applyNormalizedClipPx(
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
        normalizeClipGeometryPx(
            requestedX,
            requestedY,
            requestedWidth,
            requestedHeight,
            requestedTopLeftRadius,
            requestedTopRightRadius,
            requestedBottomRightRadius,
            requestedBottomLeftRadius,
            requestedCurveCode,
            width.toFloat(),
            height.toFloat(),
        ) { left, top, right, bottom, topLeft, topRight, bottomRight, bottomLeft, curve ->
            applyNormalizedClipPx(
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
        val shadowPath = boxShadowPath
        val shadowPaint = boxShadowPaint
        if (requestedShadowEnabled && !clipIsEmpty &&
            requestedShadowAlpha > 0f && shadowPath != null &&
            shadowPaint != null && !shadowPath.isEmpty
        ) {
            val saveCount = canvas.save()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                canvas.clipOutPath(clipPath)
            } else {
                @Suppress("DEPRECATION")
                canvas.clipPath(clipPath, Region.Op.DIFFERENCE)
            }
            canvas.drawPath(shadowPath, shadowPaint)
            canvas.restoreToCount(saveCount)
        }
        super.dispatchDraw(canvas)
    }

    private fun applyNormalizedClipPx(
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
        val radiiAreUniform = topLeftRadius == topRightRadius &&
            topLeftRadius == bottomRightRadius &&
            topLeftRadius == bottomLeftRadius
        val needsPath = curveCode == CLIP_CURVE_CONTINUOUS || !radiiAreUniform
        if (!needsPath) {
            applyNormalizedFloatRoundRectPx(
                left,
                top,
                right,
                bottom,
                topLeftRadius,
            )
            return
        }

        val isEmpty = right <= left || bottom <= top
        val outlineGeometryChanged = !outlineUsesPath ||
            left != clipLeft || top != clipTop || right != clipRight ||
            bottom != clipBottom || topLeftRadius != clipTopLeftRadius ||
            topRightRadius != clipTopRightRadius ||
            bottomRightRadius != clipBottomRightRadius ||
            bottomLeftRadius != clipBottomLeftRadius || curveCode != clipCurveCode

        clipLeft = left
        clipTop = top
        clipRight = right
        clipBottom = bottom
        clipRadius = if (radiiAreUniform) topLeftRadius else 0f
        clipTopLeftRadius = topLeftRadius
        clipTopRightRadius = topRightRadius
        clipBottomRightRadius = bottomRightRadius
        clipBottomLeftRadius = bottomLeftRadius
        clipCurveCode = curveCode
        // Path outlines retain physical-pixel floats and need no residual
        // translation compensation.
        clipResidualX = 0f
        clipResidualY = 0f
        applyClipPlacement()

        if (isEmpty != clipIsEmpty) {
            if (isEmpty) cancelAcceptedTouchStream()
            clipIsEmpty = isEmpty
            visibility = clipVisibility(isEmpty)
            importantForAccessibility = clipAccessibility(
                isEmpty,
                requestedImportantForAccessibility,
            )
        }

        if (!outlineGeometryChanged) return

        outlineUsesPath = true
        outlineUsesFloatRoundRect = false
        clipPath.reset()
        if (!isEmpty) {
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
        rebuildBoxShadowPath()
        clipContainer.invalidateOutline()
        if (requestedShadowEnabled) invalidate()
    }

    /** Uniform circular geometry stays entirely in float physical pixels. */
    private fun applyNormalizedFloatRoundRectPx(
        left: Float,
        top: Float,
        right: Float,
        bottom: Float,
        radius: Float,
    ) {
        val isEmpty = right <= left || bottom <= top
        val outlineGeometryChanged = outlineUsesPath ||
            !outlineUsesFloatRoundRect ||
            left != clipLeft || top != clipTop || right != clipRight ||
            bottom != clipBottom || radius != clipRadius

        clipLeft = left
        clipTop = top
        clipRight = right
        clipBottom = bottom
        clipRadius = radius
        clipTopLeftRadius = radius
        clipTopRightRadius = radius
        clipBottomRightRadius = radius
        clipBottomLeftRadius = radius
        clipCurveCode = CLIP_CURVE_CIRCULAR
        clipResidualX = 0f
        clipResidualY = 0f
        applyClipPlacement()

        if (isEmpty != clipIsEmpty) {
            if (isEmpty) cancelAcceptedTouchStream()
            clipIsEmpty = isEmpty
            visibility = clipVisibility(isEmpty)
            importantForAccessibility = clipAccessibility(
                isEmpty,
                requestedImportantForAccessibility,
            )
        }

        if (!outlineGeometryChanged) return
        outlineUsesPath = false
        outlineUsesFloatRoundRect = true
        clipPath.reset()
        if (!isEmpty) {
            clipPath.addRoundRect(
                left,
                top,
                right,
                bottom,
                radius,
                radius,
                Path.Direction.CW,
            )
        }
        rebuildBoxShadowPath()
        clipContainer.invalidateOutline()
        if (requestedShadowEnabled) invalidate()
    }

    /**
     * Single writer for both translations. The view carries the sub-pixel
     * remainder of the clip origin; the content container subtracts it back out
     * so only the clip edge moves and the content stays exactly where the
     * driver put it. Every write self-dedupes inside View.setTranslationX, so
     * calling this on an unchanged frame costs four float comparisons.
     */
    private fun applyClipPlacement() {
        super.setTranslationX(userTranslationX + clipResidualX)
        super.setTranslationY(userTranslationY + clipResidualY)
        contentContainer.translationX = requestedContentTranslateX - clipResidualX
        contentContainer.translationY = requestedContentTranslateY - clipResidualY
        // Scale is intentionally centered and lives on the content only. View
        // translation properties are applied independently of scale, so a
        // caller's tx/ty remains a physical-pixel offset rather than scaling
        // around the origin with the content.
        contentContainer.pivotX = contentContainer.width / 2f
        contentContainer.pivotY = contentContainer.height / 2f
        contentContainer.scaleX = requestedContentScale
        contentContainer.scaleY = requestedContentScale
    }

    // The clip's sub-pixel placement and the consumer's `transform` prop share
    // one property, so they are composed rather than allowed to overwrite each
    // other. RN routes every transform write through these setters
    // (BaseViewManager.setTransformProperty), so intercepting them is enough.
    //
    // The getters are deliberately NOT overridden to hide the residual:
    // View.setTranslationX dedupes by calling getTranslationX() virtually, so
    // reporting the consumer's value there would make every write look like a
    // change and re-invalidate the view on frames where nothing moved. The cost
    // of leaving them alone is that a read-modify-write of translationX picks up
    // the residual twice — sub-pixel, and nothing in RN's transform path reads
    // back before writing.
    override fun setTranslationX(translationX: Float) {
        userTranslationX = translationX
        super.setTranslationX(translationX + clipResidualX)
    }

    override fun setTranslationY(translationY: Float) {
        userTranslationY = translationY
        super.setTranslationY(translationY + clipResidualY)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        clipContainer.layout(0, 0, w, h)
        contentContainer.layout(0, 0, w, h)
        applyClipPlacement()
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
        // The event arrives in this view's local space, which the parent has
        // already inverse-transformed by the residual translation. Adding it
        // back maps the point into the space clipLeft/clipTop are expressed in,
        // so hit testing stays against the geometry the driver delivered — the
        // same test as before the residual existed.
        if (outlineUsesPath) {
            // Reuse the exact cubic path supplied to Outline.setPath: hit
            // testing must follow the rendered aperture, including its
            // portable continuous-curve approximation.
            return !clipIsEmpty && containsPathPoint(clipPath, x, y)
        }
        return containsRoundedPointPx(
            x + clipResidualX,
            y + clipResidualY,
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
                clearTouchState()
                acceptingTouchStream = containsRoundedPoint(event.x, event.y)
                if (!acceptingTouchStream) return false
                val accepted = super.dispatchTouchEvent(event)
                if (accepted) {
                    retainTouchEvent(event)
                } else {
                    clearTouchState()
                }
                return accepted
            }
            MotionEvent.ACTION_CANCEL, MotionEvent.ACTION_UP -> {
                val result = if (acceptingTouchStream) {
                    super.dispatchTouchEvent(event)
                } else {
                    false
                }
                clearTouchState()
                return result
            }
        }

        if (!acceptingTouchStream) return false
        val result = super.dispatchTouchEvent(event)
        retainTouchEvent(event)
        return result
    }

    private fun retainTouchEvent(event: MotionEvent) {
        retainedTouchEvent?.recycle()
        retainedTouchEvent = MotionEvent.obtain(event)
    }

    private fun clearTouchState() {
        acceptingTouchStream = false
        retainedTouchEvent?.recycle()
        retainedTouchEvent = null
    }

    private fun cancelAcceptedTouchStream() {
        val latest = retainedTouchEvent
        if (!acceptingTouchStream || latest == null) {
            clearTouchState()
            return
        }
        val cancel = MotionEvent.obtain(latest)
        cancel.action = MotionEvent.ACTION_CANCEL
        // Terminal BEFORE dispatch: a child's synchronous cancel handler can
        // re-enter geometry application, and a nested emptiness transition
        // must observe an already-ended stream instead of synthesizing a
        // second cancel for it.
        clearTouchState()
        try {
            super.dispatchTouchEvent(cancel)
        } finally {
            cancel.recycle()
        }
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
        clipResidualX = 0f
        clipResidualY = 0f
        applyClipPlacement()
        outlineUsesPath = false
        outlineUsesFloatRoundRect = false
        clipPath.reset()
        outlineLeft = 0
        outlineTop = 0
        outlineRight = 0
        outlineBottom = 0
        requestedImportantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_AUTO
        applyRequestedGeometry()
    }
}
