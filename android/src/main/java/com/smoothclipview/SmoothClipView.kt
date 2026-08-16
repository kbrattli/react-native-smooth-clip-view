package com.smoothclipview

import android.content.res.Configuration
import android.graphics.Outline
import android.os.Trace
import android.view.MotionEvent
import android.view.View
import android.view.ViewOutlineProvider
import com.facebook.proguard.annotations.DoNotStrip
import com.facebook.react.uimanager.PixelUtil
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.views.view.ReactViewGroup

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
        requestedContentTranslateX = nextContentTranslateX
        requestedContentTranslateY = nextContentTranslateY
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
        // Debug-only Perfetto slice for the Kotlin share of the C++
        // SmoothClip.setPresentation section (see SmoothClipTrace.h).
        if (BuildConfig.DEBUG) Trace.beginSection("SmoothClip.applyPx")
        try {
            // Stored only; applyNormalizedClipPx computes the clip residual and
            // applyClipPlacement writes both translations together, because the
            // content's final offset depends on the residual as well.
            requestedContentTranslateX = contentTranslateX
            requestedContentTranslateY = contentTranslateY
            applyNormalizedClipPx(left, top, right, bottom, radius)
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
        // Far edges are derived, not rounded independently: see outlineFarEdge.
        // Independent rounding breathes the emitted size by 1 px under pure
        // translation, which is the visible artifact once an animation's tail
        // slows below a pixel per frame.
        val nextOutlineLeft = outlineOrigin(left)
        val nextOutlineTop = outlineOrigin(top)
        val nextOutlineRight = outlineFarEdge(left, right)
        val nextOutlineBottom = outlineFarEdge(top, bottom)
        // Outline.setRoundRect collapses a degenerate integer rect to empty.
        // Use the exact emitted geometry as the single semantic source for
        // rendering, visibility, accessibility and hit testing.
        val isEmpty = outlineRectIsEmpty(
            nextOutlineLeft,
            nextOutlineTop,
            nextOutlineRight,
            nextOutlineBottom,
        )
        val outlineGeometryChanged = outlineChanged(
            nextOutlineLeft,
            nextOutlineTop,
            nextOutlineRight,
            nextOutlineBottom,
            radius,
            outlineLeft,
            outlineTop,
            outlineRight,
            outlineBottom,
            clipRadius,
        )

        clipLeft = left
        clipTop = top
        clipRight = right
        clipBottom = bottom
        clipRadius = radius
        // Whatever integer rounding threw away, carried on this view's own
        // translation so the clip edge still lands where the driver asked
        // instead of snapping to the pixel grid while the content it clips
        // slides in floats. It is a single scalar per axis only because the far
        // edges are derived from the origin — with independently rounded edges
        // no one translation could place both.
        clipResidualX = left - nextOutlineLeft
        clipResidualY = top - nextOutlineTop
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

        // An emptiness transition necessarily changes at least one emitted
        // edge, so the existing edge/radius key cannot skip invalidateOutline.
        if (!outlineGeometryChanged) return

        outlineLeft = nextOutlineLeft
        outlineTop = nextOutlineTop
        outlineRight = nextOutlineRight
        outlineBottom = nextOutlineBottom
        // Schedules the traversal too: invalidateOutline() ends in
        // invalidateViewProperty(), which damages this view in its parent up
        // to ViewRootImpl.scheduleTraversals(). A plain invalidate() on top
        // would only add PFLAG_INVALIDATED, forcing a display-list re-record
        // every frame to restage an outline the RenderNode applies as a
        // property.
        invalidateOutline()
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
        requestedRadius = 0f
        requestedContentTranslateX = 0f
        requestedContentTranslateY = 0f
        clipResidualX = 0f
        clipResidualY = 0f
        applyClipPlacement()
        outlineLeft = 0
        outlineTop = 0
        outlineRight = 0
        outlineBottom = 0
        requestedImportantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_AUTO
        applyRequestedGeometry()
    }
}
