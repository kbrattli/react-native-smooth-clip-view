package com.smoothclipview

import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Outline
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Region
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import android.os.Trace
import android.view.MotionEvent
import android.view.View
import android.view.ViewOutlineProvider
import com.facebook.proguard.annotations.DoNotStrip
import com.facebook.react.uimanager.PixelUtil
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.views.view.ReactViewGroup
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.roundToInt
import kotlin.math.abs
import kotlin.math.pow
import kotlin.math.cos
import kotlin.math.sin

class SmoothClipView(context: ThemedReactContext) : ReactViewGroup(context) {
    private val clipPath = Path()
    private val supportsPathOutlineClipping =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
    private val clipContainer: ReactViewGroup =
        if (supportsPathOutlineClipping) {
            ReactViewGroup(context)
        } else {
            object : ReactViewGroup(context) {
                override fun dispatchDraw(canvas: Canvas) {
                    val saveCount = canvas.save()
                    canvas.clipPath(clipPath)
                    try {
                        super.dispatchDraw(canvas)
                    } finally {
                        canvas.restoreToCount(saveCount)
                    }
                }
            }
        }
    // One compositing group; arbitrary React children may overlap when faded.
    internal val presentationContainer = object : ReactViewGroup(context) {
        override fun hasOverlappingRendering(): Boolean = true
        override fun dispatchDraw(canvas: Canvas) {
            drawBoxShadow(canvas)
            super.dispatchDraw(canvas)
        }
    }
    private var requestedRotation = 0.0
    private var requestedOpacity = 1f
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
    private var boxShadowPath: Path? = null
    private var boxShadowPaint: Paint? = null
    // `shadowRendering="baked"`: draw the shadow from one pre-blurred tile per
    // radius step, stretched in nine pieces, instead of blurring a path on
    // every frame the aperture moves. Like iOS, the tile is drawn under the
    // aperture too (the blur path cuts it out); content is expected opaque.
    private var bakedShadows = false
    private var bakedShadowTile: BakedShadowTile? = null
    private var bakedShadowPaint: Paint? = null
    private val bakedSrc = Rect()
    private val bakedDst = RectF()
    private val bakedXs = FloatArray(4)
    private val bakedYs = FloatArray(4)
    private val bakedSx = IntArray(4)
    private var clipIsEmpty = true
    private var requestedImportantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_AUTO
    private var autonomousMotion = false
    private var acceptingTouchStream = false
    private var forwardingOverflowTouchStream = false
    private val inversePresentationMatrix = Matrix()
    private val touchPoint = FloatArray(2)

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

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                // Outline.setRoundRect only accepts integer edges. The raw path
                // keeps sub-pixel coordinates and off-host geometry intact.
                outline.setPath(clipPath)
            } else {
                outline.setEmpty()
            }
        }
    }

    init {
        clipContainer.addView(contentContainer)
        presentationContainer.addView(clipContainer)
        super.addView(presentationContainer)
        if (supportsPathOutlineClipping) {
            clipContainer.outlineProvider = clipOutlineProvider
            clipContainer.clipToOutline = true
        }
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
        rotation: Double = 0.0,
        opacity: Double = 1.0,
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
            !shadowSpreadDistance.isFinite() || !rotation.isFinite() || !opacity.isFinite() || contentScale <= 0.0 ||
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
        requestedRotation = rotation
        requestedOpacity = opacity.coerceIn(0.0, 1.0).toFloat()
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
        rotation: Double = 0.0,
        opacity: Float = 1f,
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
            !shadowSpreadDistance.isFinite() || !rotation.isFinite() || !opacity.isFinite() || contentScale <= 0f ||
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
            requestedRotation = rotation
            requestedOpacity = opacity.coerceIn(0f, 1f)
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
            if (wasVisible) presentationContainer.invalidate()
            return
        }
        if (paintChanged || boxShadowPaint == null) updateBoxShadowPaint()
        if (pathChanged || !wasVisible || boxShadowPath == null) {
            rebuildBoxShadowPath()
        }
        if (paintChanged || pathChanged || !wasVisible) presentationContainer.invalidate()
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

    fun setBakedShadows(enabled: Boolean) {
        if (bakedShadows == enabled) return
        bakedShadows = enabled
        if (!enabled) bakedShadowTile = null
        if (requestedShadowEnabled && requestedShadowAlpha > 0f) {
            rebuildBoxShadowPath()
            presentationContainer.invalidate()
        }
    }

    private fun usesBakedShadow(): Boolean {
        if (!bakedShadows || clipTopLeftRadius != clipTopRightRadius ||
            clipTopLeftRadius != clipBottomRightRadius ||
            clipTopLeftRadius != clipBottomLeftRadius
        ) {
            return false
        }
        // A shape too small for two corner pieces on a side, 2 x (margin +
        // radius), keeps the blur path: overlapping pieces do not add up to
        // the blur tails the true shadow overlaps.
        val margin = kotlin.math.ceil(1.5f * requestedShadowBlurRadius.coerceAtLeast(0f))
        val minimumSide = 2f * (margin + bakedShadowTileRadius())
        val spread = 2f * requestedShadowSpreadDistance
        return clipRight - clipLeft + spread >= minimumSide &&
            clipBottom - clipTop + spread >= minimumSide
    }

    /** Radius step, in px, of the tile the current shadow draws from. */
    private fun bakedShadowTileRadius(): Float {
        val radius = adjustedRadiusForSpread(clipTopLeftRadius, requestedShadowSpreadDistance)
        val step = BAKED_SHADOW_RADIUS_STEP_DP * resources.displayMetrics.density
        return if (step > 0f) kotlin.math.ceil(radius / step) * step else radius
    }

    private fun rebuildBoxShadowPath() {
        if (!requestedShadowEnabled || requestedShadowAlpha <= 0f) return
        if (usesBakedShadow()) {
            // The tile replaces the path; a stale path must not be drawn if
            // the radii later stop being uniform before a rebuild.
            boxShadowPath?.rewind()
            return
        }
        val path = boxShadowPath ?: Path().also { boxShadowPath = it }
        // Keeps the path's storage across frames; reset() may free it.
        path.rewind()
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
            super.dispatchDraw(canvas)
        } finally {
            canvas.restoreToCount(hostSaveCount)
        }
    }

    private fun bakedShadowTile(): BakedShadowTile? {
        val density = resources.displayMetrics.density
        val step = BAKED_SHADOW_RADIUS_STEP_DP * density
        val tileRadius = bakedShadowTileRadius()
        val band = maxOf(2, (2f * density).roundToInt())
        val rgb = Color.rgb(
            (requestedShadowRed * 255f).roundToInt(),
            (requestedShadowGreen * 255f).roundToInt(),
            (requestedShadowBlue * 255f).roundToInt(),
        )
        val current = bakedShadowTile
        if (current != null && current.matches(tileRadius, clipCurveCode, requestedShadowBlurRadius, rgb)) {
            return current
        }
        // A stand-in from a neighbouring step does not match, so the next
        // frame asks again and picks up the exact tile once it has landed.
        return BakedShadowTiles.getOrRequest(
            tileRadius, clipCurveCode, requestedShadowBlurRadius, rgb, band, step, this,
        ).also { bakedShadowTile = it }
    }

    /** The exact tile for the current radius step has landed: draw it. */
    internal fun shadowTileDidLand() {
        if (!requestedShadowEnabled || requestedShadowAlpha <= 0f || !usesBakedShadow()) return
        presentationContainer.invalidate()
    }

    private fun drawBakedBoxShadow(canvas: Canvas) {
        val tile = bakedShadowTile() ?: return
        val spread = requestedShadowSpreadDistance
        val margin = tile.margin.toFloat()
        val left = clipLeft - spread + requestedShadowOffsetX - margin
        val top = clipTop - spread + requestedShadowOffsetY - margin
        val right = clipRight + spread + requestedShadowOffsetX + margin
        val bottom = clipBottom + spread + requestedShadowOffsetY + margin
        if (right <= left || bottom <= top) return
        val paint = bakedShadowPaint ?: Paint(Paint.FILTER_BITMAP_FLAG).also {
            bakedShadowPaint = it
        }
        paint.alpha = (requestedShadowAlpha * 255f).roundToInt().coerceIn(0, 255)
        val corner = tile.corner.toFloat()
        // Nine pieces: corners keep their size, edges stretch one way, the
        // centre both ways. A destination too small for two corners draws
        // them overlapping and skips the middle pieces.
        bakedXs[0] = left; bakedXs[1] = left + corner
        bakedXs[2] = right - corner; bakedXs[3] = right
        bakedYs[0] = top; bakedYs[1] = top + corner
        bakedYs[2] = bottom - corner; bakedYs[3] = bottom
        bakedSx[0] = 0; bakedSx[1] = tile.corner
        bakedSx[2] = tile.corner + tile.band; bakedSx[3] = tile.side
        for (row in 0 until 3) {
            for (col in 0 until 3) {
                bakedDst.set(bakedXs[col], bakedYs[row], bakedXs[col + 1], bakedYs[row + 1])
                if (bakedDst.right <= bakedDst.left || bakedDst.bottom <= bakedDst.top) continue
                bakedSrc.set(bakedSx[col], bakedSx[row], bakedSx[col + 1], bakedSx[row + 1])
                canvas.drawBitmap(tile.bitmap, bakedSrc, bakedDst, paint)
            }
        }
    }

    private fun drawBoxShadow(canvas: Canvas) {
        if (!requestedShadowEnabled || clipIsEmpty || requestedShadowAlpha <= 0f) return
        if (usesBakedShadow()) {
            drawBakedBoxShadow(canvas)
            return
        }
        val shadowPath = boxShadowPath
        val shadowPaint = boxShadowPaint
        if (shadowPath != null && shadowPaint != null && !shadowPath.isEmpty) {
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
        clipTopLeftRadius = topLeftRadius
        clipTopRightRadius = topRightRadius
        clipBottomRightRadius = bottomRightRadius
        clipBottomLeftRadius = bottomLeftRadius
        clipCurveCode = curveCode
        applyContentTransform()

        clipIsEmpty = isEmpty
        applyPresentationTransform()
        reapplyClipPresentation()

        if (!geometryChanged) return

        updateOverflowInsets()
        clipPath.rewind()
        if (!isEmpty) {
            // One builder for clip, shadow and hit testing; it keeps a uniform
            // circular corner as an rrect for the renderer's fast paths.
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
        if (supportsPathOutlineClipping) {
            clipContainer.invalidateOutline()
        } else {
            clipContainer.invalidate()
        }
        if (requestedShadowEnabled) presentationContainer.invalidate()
    }

    private fun updateOverflowInsets() {
        // React Native's touch-target walk also needs to see the unrotated overflow.
        val left = kotlin.math.floor(minOf(0f, clipLeft).toDouble()).toInt()
        val top = kotlin.math.floor(minOf(0f, clipTop).toDouble()).toInt()
        val right = kotlin.math.floor(minOf(0f, width - clipRight).toDouble()).toInt()
        val bottom = kotlin.math.floor(minOf(0f, height - clipBottom).toDouble()).toInt()
        presentationContainer.setOverflowInset(left, top, right, bottom)
        clipContainer.setOverflowInset(left, top, right, bottom)
    }

    private fun applyPresentationTransform() {
        // The pivot is immaterial at zero rotation; avoid dirtying a stationary parent.
        val cx = if (requestedRotation == 0.0) 0f else (clipLeft + clipRight) / 2f
        val cy = if (requestedRotation == 0.0) 0f else (clipTop + clipBottom) / 2f
        // Keep unwrapped doubles in the registry. Only the render transform is periodic.
        val degrees = Math.toDegrees(requestedRotation % (2 * Math.PI)).toFloat()
        if (presentationContainer.pivotX != cx) presentationContainer.pivotX = cx
        if (presentationContainer.pivotY != cy) presentationContainer.pivotY = cy
        if (presentationContainer.rotation != degrees) presentationContainer.rotation = degrees
        if (presentationContainer.alpha != requestedOpacity) presentationContainer.alpha = requestedOpacity
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
        presentationContainer.layout(0, 0, w, h)
        clipContainer.layout(0, 0, w, h)
        contentContainer.layout(0, 0, w, h)
        updateOverflowInsets()
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
        if (clipIsEmpty || requestedOpacity <= 0f) return false
        val cx = (clipLeft + clipRight) / 2.0
        val cy = (clipTop + clipBottom) / 2.0
        val c = cos(requestedRotation)
        val sn = sin(requestedRotation)
        val localX = cx + c * (x - cx) + sn * (y - cy)
        val localY = cy - sn * (x - cx) + c * (y - cy)
        return containsPathPoint(clipPath, localX.toFloat(), localY.toFloat())
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        val action = event.actionMasked
        if (action == MotionEvent.ACTION_DOWN) {
            // The aperture gates admission only. Once accepted, the stream
            // belongs to Android until its real UP or CANCEL arrives.
            clearTouchState()
            if (event.x < 0 || event.y < 0 || event.x >= width || event.y >= height ||
                !containsRoundedPoint(event.x, event.y)) return false
            acceptingTouchStream = true
            presentationContainer.matrix.invert(inversePresentationMatrix)
            touchPoint[0] = event.x
            touchPoint[1] = event.y
            inversePresentationMatrix.mapPoints(touchPoint)
            forwardingOverflowTouchStream = touchPoint[0] < 0 || touchPoint[1] < 0 ||
                touchPoint[0] >= width || touchPoint[1] >= height
        }

        if (!acceptingTouchStream) return false
        // ViewGroup's native dispatch rejects children outside their layout bounds,
        // even when clipChildren=false. Bypass only the internal presentation wrapper
        // for an overflow stream; the clip container still dispatches to transformed
        // content normally. Retain this route through the real UP/CANCEL.
        val result = if (forwardingOverflowTouchStream) {
            presentationContainer.matrix.invert(inversePresentationMatrix)
            val localEvent = MotionEvent.obtain(event)
            try {
                localEvent.transform(inversePresentationMatrix)
                clipContainer.dispatchTouchEvent(localEvent)
            } finally {
                localEvent.recycle()
            }
        } else {
            super.dispatchTouchEvent(event)
        }
        if ((action == MotionEvent.ACTION_DOWN && !result) ||
            action == MotionEvent.ACTION_CANCEL || action == MotionEvent.ACTION_UP
        ) {
            clearTouchState()
        }
        return result
    }

    private fun clearTouchState() {
        acceptingTouchStream = false
        forwardingOverflowTouchStream = false
    }

    fun setRequestedImportantForAccessibility(value: Int) {
        requestedImportantForAccessibility = value
        reapplyClipPresentation()
    }

    @DoNotStrip
    fun setAutonomousMotion(active: Boolean) {
        if (autonomousMotion == active) return
        autonomousMotion = active
        reapplyClipPresentation()
    }

    fun reapplyClipPresentation() {
        val apertureVisible = apertureIntersectsHost()
        val expectedVisibility = renderVisibility(
            requestedOpacity > 0f && (apertureVisible || shadowIntersectsHost()),
        )
        if (visibility != expectedVisibility) {
            visibility = expectedVisibility
        }

        val expectedAccessibility = clipAccessibility(
            autonomousMotion || !apertureVisible || requestedOpacity <= 0f,
            requestedImportantForAccessibility,
        )
        if (importantForAccessibility != expectedAccessibility) {
            importantForAccessibility = expectedAccessibility
        }
    }

    private fun apertureIntersectsHost(): Boolean =
        !clipIsEmpty && rotatedRectIntersectsHost(
            clipLeft.toDouble(), clipTop.toDouble(), clipRight.toDouble(), clipBottom.toDouble(),
            (clipLeft + clipRight) / 2.0, (clipTop + clipBottom) / 2.0,
            requestedRotation, width.toDouble(), height.toDouble(),
        )

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
        return rotatedRectIntersectsHost(
            (pathLeft - blurOutset).toDouble(), (pathTop - blurOutset).toDouble(),
            (pathRight + blurOutset).toDouble(), (pathBottom + blurOutset).toDouble(),
            (clipLeft + clipRight) / 2.0, (clipTop + clipBottom) / 2.0,
            requestedRotation, width.toDouble(), height.toDouble(),
        )
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
        requestedRotation = 0.0
        requestedOpacity = 1f
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
        bakedShadowTile = null
        applyContentTransform()
        clipPath.rewind()
        requestedImportantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_AUTO
        applyRequestedGeometry()
    }
}

/** Corner-radius step baked shadow tiles are rounded up to, in dp. */
internal const val BAKED_SHADOW_RADIUS_STEP_DP = 4f

/**
 * One pre-blurred rounded-rect shadow, square, with the shape inset by
 * [margin] (3σ = 1.5 × the CSS blur) on every side and a stretchable band of
 * [band] px between the corner regions of [corner] px. Colour is opaque; the
 * shadow alpha is applied by the drawing paint.
 */
internal class BakedShadowTile(
    val bitmap: Bitmap,
    val radius: Float,
    val curveCode: Int,
    val blurRadius: Float,
    val rgb: Int,
    val margin: Int,
    val band: Int,
) {
    val corner: Int = 2 * margin + radius.roundToInt()
    val side: Int = bitmap.width

    fun matches(radius: Float, curveCode: Int, blurRadius: Float, rgb: Int): Boolean =
        this.radius == radius && this.curveCode == curveCode &&
            this.blurRadius == blurRadius && this.rgb == rgb
}

/**
 * Process-wide tile cache: a handful of (radius step, curve, blur, colour).
 *
 * A bake costs a bitmap allocation plus a software blur, growing with
 * blur² × density², so it stays off the frame: a missing tile is requested on
 * a background thread while the nearest cached step stands in, and only a
 * cold cache (nothing near to show, at mount) bakes on the calling thread.
 */
internal object BakedShadowTiles {
    private const val MAX_TILES = 12
    /** Radius steps searched on either side of a missing tile for a stand-in. */
    private const val SEARCH_STEPS = 16
    private val tiles = LinkedHashMap<String, BakedShadowTile>(MAX_TILES, 0.75f, true)
    private val pending = LinkedHashMap<String, PendingTile>()
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }
    private val worker by lazy {
        val thread = HandlerThread("SmoothClipShadowTiles", Process.THREAD_PRIORITY_BACKGROUND)
        thread.start()
        Handler(thread.looper)
    }
    /** Where a requested bake runs and where its result lands; tests swap in queues they drain. */
    internal var runBake: (Runnable) -> Unit = { worker.post(it) }
    internal var runOnMain: (Runnable) -> Unit = { mainHandler.post(it) }
    /** Tiles baked so far in this process; tests read it. */
    val bakeCount = AtomicInteger()

    private class PendingTile(
        val radius: Float,
        val curveCode: Int,
        val blurRadius: Float,
        val rgb: Int,
        val band: Int,
    ) {
        val requesters = mutableListOf<WeakReference<SmoothClipView>>()
    }

    private fun key(radius: Float, curveCode: Int, blurRadius: Float, rgb: Int, band: Int): String =
        "$radius|$curveCode|$blurRadius|$rgb|$band"

    /**
     * The tile for this radius step when cached. Otherwise the nearest cached
     * step (the rounder neighbour first: a tile corner tighter than the clip
     * corner over it reads as a dark sliver, a rounder one only recedes under
     * the clip) while the exact tile bakes on the background thread, after
     * which [requester] is asked to draw again. Nothing near: baked now.
     */
    @Synchronized
    fun getOrRequest(
        radius: Float,
        curveCode: Int,
        blurRadius: Float,
        rgb: Int,
        band: Int,
        stepPx: Float,
        requester: SmoothClipView?,
    ): BakedShadowTile? {
        val key = key(radius, curveCode, blurRadius, rgb, band)
        tiles[key]?.let { return it }
        val standIn = if (stepPx > 0f) nearest(radius, curveCode, blurRadius, rgb, band, stepPx) else null
        if (standIn == null) {
            return bake(radius, curveCode, blurRadius, rgb, band)?.also { store(key, it) }
        }
        request(key, PendingTile(radius, curveCode, blurRadius, rgb, band), requester)
        return standIn
    }

    private fun nearest(
        radius: Float,
        curveCode: Int,
        blurRadius: Float,
        rgb: Int,
        band: Int,
        stepPx: Float,
    ): BakedShadowTile? {
        for (distance in 1..SEARCH_STEPS) {
            val delta = distance * stepPx
            tiles[key(radius + delta, curveCode, blurRadius, rgb, band)]?.let { return it }
            if (radius - delta < 0f) continue
            tiles[key(radius - delta, curveCode, blurRadius, rgb, band)]?.let { return it }
        }
        return null
    }

    private fun store(key: String, tile: BakedShadowTile) {
        tiles[key] = tile
        if (tiles.size > MAX_TILES) {
            val eldest = tiles.entries.iterator()
            eldest.next()
            eldest.remove()
        }
    }

    private fun request(key: String, tile: PendingTile, requester: SmoothClipView?) {
        val existing = pending[key]
        if (existing != null) {
            // One entry per view: a stand-in never matches, so the same view
            // asks again on every draw until the exact tile lands.
            if (requester != null && existing.requesters.none { it.get() === requester }) {
                existing.requesters += WeakReference(requester)
            }
            return
        }
        if (requester != null) tile.requesters += WeakReference(requester)
        pending[key] = tile
        runBake {
            val baked = bake(tile.radius, tile.curveCode, tile.blurRadius, tile.rgb, tile.band)
            runOnMain { land(key, baked) }
        }
    }

    private fun land(key: String, tile: BakedShadowTile?) {
        val entry = synchronized(this) {
            val removed = pending.remove(key)
            if (tile != null && removed != null) store(key, tile)
            removed
        }
        if (tile == null || entry == null) return
        for (requester in entry.requesters) requester.get()?.shadowTileDidLand()
    }

    private fun bake(radius: Float, curveCode: Int, blurRadius: Float, rgb: Int, band: Int): BakedShadowTile? {
        val margin = kotlin.math.ceil(1.5f * blurRadius.coerceAtLeast(0f)).toInt()
        val corner = 2 * margin + radius.roundToInt()
        val side = 2 * corner + band
        if (side <= 0 || side > 4096) return null
        bakeCount.incrementAndGet()
        val bitmap = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888)
        val path = Path()
        val inset = margin.toFloat()
        appendRoundedRectPath(
            path, inset, inset, side - inset, side - inset,
            radius, radius, radius, radius, curveCode,
        )
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        paint.color = rgb or (0xFF shl 24)
        val sigma = blurRadius * 0.5f
        if (sigma > 0.5f) {
            paint.maskFilter = BlurMaskFilter((sigma - 0.5f) / 0.57735f, BlurMaskFilter.Blur.NORMAL)
        }
        Canvas(bitmap).drawPath(path, paint)
        return BakedShadowTile(bitmap, radius, curveCode, blurRadius, rgb, margin, band)
    }
}
