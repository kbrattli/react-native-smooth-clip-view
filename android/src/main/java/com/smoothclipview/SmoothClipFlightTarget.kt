package com.smoothclipview

import android.view.MotionEvent
import android.view.View
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.views.view.ReactViewGroup

/**
 * The landing end of a flight (`<SmoothClipFlightTarget tag>`). Fabric
 * children mount into [contentContainer], which only this view writes to:
 * while a SmoothClipView with the same tag is airborne the container is
 * covered (alpha 0, no touches, hidden from accessibility) and the target's
 * own React styles stay untouched.
 */
class SmoothClipFlightTarget(context: ThemedReactContext) : ReactViewGroup(context) {
    internal val contentContainer = ReactViewGroup(context)

    /** The `flightTag` prop; '' means no flight lands here. */
    internal var flightTag: String = ""
        private set

    /** The `ready` prop: while false a landing flight keeps its own pixels up. */
    internal var flightReady: Boolean = true
        private set

    /** True while an airborne flight with [flightTag] covers this target. */
    internal var flightCovered: Boolean = false
        private set

    /**
     * Fabric dropped the view while it was still in a window: a popped
     * screen's exit animation draws it (react-native-screens keeps the
     * exiting views attached). It stays registered until it leaves the
     * window, so a flight still covers it and departs from it, but it never
     * receives a landing and no landing uncovers it.
     */
    internal var flightDropped: Boolean = false
        private set

    private var pendingTag: String? = null
    private var pendingReady: Boolean? = null

    init {
        super.addView(contentContainer)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        contentContainer.layout(0, 0, w, h)
    }

    internal fun setPendingTag(value: String) {
        pendingTag = value
    }

    internal fun setPendingReady(value: Boolean) {
        pendingReady = value
    }

    /** Applies the props of one Fabric transaction together. */
    internal fun commitProps() {
        val tag = pendingTag
        val ready = pendingReady
        pendingTag = null
        pendingReady = null
        val tagChanged = tag != null && tag != flightTag
        val readyChanged = ready != null && ready != flightReady
        if (ready != null) flightReady = ready
        if (tagChanged) {
            val oldTag = flightTag
            flightTag = tag!!
            SmoothClipFlightTargets.targetTagChanged(this, oldTag)
        } else if (readyChanged) {
            SmoothClipFlightTargets.targetStateChanged(this, retryNow = true)
        }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        SmoothClipFlightTargets.targetStateChanged(this, retryNow = false)
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        if (flightDropped) {
            releaseFlightTarget(retryNow = false)
        } else {
            SmoothClipFlightTargets.targetStateChanged(this, retryNow = false)
        }
    }

    /** Fabric dropped the view: it can no longer receive a landing. */
    internal fun dropFlightTarget() {
        pendingTag = null
        pendingReady = null
        if (isAttachedToWindow) {
            flightDropped = true
        } else {
            releaseFlightTarget(retryNow = true)
        }
    }

    /** Leaves the registry, uncovered. */
    private fun releaseFlightTarget(retryNow: Boolean) {
        flightDropped = false
        if (flightTag.isNotEmpty()) {
            val oldTag = flightTag
            flightTag = ""
            SmoothClipFlightTargets.targetTagChanged(this, oldTag, retryNow)
        }
        setFlightCovered(false)
        flightReady = true
    }

    internal fun setFlightCovered(covered: Boolean) {
        if (flightCovered == covered) return
        flightCovered = covered
        // Alpha keeps the container's display list, so the reveal in the
        // landing frame re-records nothing; INVISIBLE would drop it.
        contentContainer.alpha = if (covered) 0f else 1f
        contentContainer.importantForAccessibility = if (covered) {
            View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        } else {
            View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
        }
    }

    /** A covered target takes no touches: the flight is what the user sees. */
    override fun dispatchTouchEvent(event: MotionEvent): Boolean =
        if (flightCovered) false else super.dispatchTouchEvent(event)

    /** Attached, not dropped, and its screen is not running an enter/exit animation. */
    internal fun isSettled(): Boolean =
        isAttachedToWindow && !flightDropped && !isInScreenTransition(this)
}
