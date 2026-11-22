package com.smoothclipview

import android.content.Context
import android.graphics.Matrix
import android.os.SystemClock
import android.view.Choreographer
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import com.facebook.react.uimanager.RootView
import java.lang.ref.WeakReference
import kotlin.math.abs
import kotlin.math.max

// Codes shared with the C++ registry (SmoothClipRegistry.cpp, kFlight*).
/** flightLift(): the host does not fly (flight off, detached, or not representable). */
internal const val FLIGHT_LIFT_NONE = 0
/** flightLift(): the host left its screen now; the registry captures the rest presentation. */
internal const val FLIGHT_LIFT_NEW = 1
/** flightLift(): the host was already airborne; the run continues the same lift. */
internal const val FLIGHT_LIFT_CONTINUED = 2

/** flightRunEnded(): nothing was airborne. */
internal const val FLIGHT_LAND_NONE = 0
/** flightRunEnded(): handed off to the target; the registry resets the host to rest. */
internal const val FLIGHT_LAND_HANDOFF = 1
/** flightRunEnded(): back in the host, which keeps the landed presentation. */
internal const val FLIGHT_LAND_RETURNED = 2
/** flightRunEnded(): the content stays in the flight layer until a retry lands it. */
internal const val FLIGHT_LAND_HELD = 3

/** A detached host with no target takes its content back after this long. */
internal const val FLIGHT_FALLBACK_MS = 300L

/**
 * Host-to-window affine of [view] in pixels, as `[a, b, c, d, tx, ty]` with
 * `x' = a x + c y + tx` and `y' = b x + d y + ty`. Walks the model hierarchy:
 * each view's `left`/`top`, its parent's scroll and its own `getMatrix()`
 * (translation, scale and rotation about the pivot). A view that is not
 * attached ends the chain at its topmost ancestor. Returns false for a 3D
 * (perspective) transform, which no presentation can express.
 *
 * The same walk writes [rootOut], when given: the affine into the nearest
 * React root ancestor's coordinates (a [RootView]: ReactRootView,
 * ReactSurfaceView or a Modal's dialog root), or the window affine outside
 * one. That is window space for `space: 'window'`: layout, safe-area insets,
 * Reanimated's `measure()` and `measureInWindow` are relative to the root.
 * Without edge-to-edge the root starts below the status bar, and React
 * Native's viewport offset leaves that out of `measureInWindow` too.
 */
internal fun viewToWindowAffine(
    view: View,
    out: DoubleArray,
    rootOut: DoubleArray? = null,
): Boolean {
    var a = 1.0
    var b = 0.0
    var c = 0.0
    var d = 1.0
    var tx = 0.0
    var ty = 0.0
    val values = FloatArray(9)
    var current: View = view
    var rootFound = rootOut == null
    while (true) {
        if (!rootFound && current !== view && current is RootView) {
            rootFound = true
            rootOut?.setAffine(a, b, c, d, tx, ty)
        }
        var la = 1.0
        var lb = 0.0
        var lc = 0.0
        var ld = 1.0
        var ltx = 0.0
        var lty = 0.0
        val matrix = current.matrix
        if (!matrix.isIdentity) {
            matrix.getValues(values)
            if (abs(values[Matrix.MPERSP_0]) > 1e-6f || abs(values[Matrix.MPERSP_1]) > 1e-6f ||
                abs(values[Matrix.MPERSP_2] - 1f) > 1e-6f
            ) {
                return false
            }
            la = values[Matrix.MSCALE_X].toDouble()
            lc = values[Matrix.MSKEW_X].toDouble()
            ltx = values[Matrix.MTRANS_X].toDouble()
            lb = values[Matrix.MSKEW_Y].toDouble()
            ld = values[Matrix.MSCALE_Y].toDouble()
            lty = values[Matrix.MTRANS_Y].toDouble()
        }
        val parent = current.parent as? View
        ltx += current.left - (parent?.scrollX ?: 0)
        lty += current.top - (parent?.scrollY ?: 0)
        val na = la * a + lc * b
        val nb = lb * a + ld * b
        val nc = la * c + lc * d
        val nd = lb * c + ld * d
        val ntx = la * tx + lc * ty + ltx
        val nty = lb * tx + ld * ty + lty
        a = na
        b = nb
        c = nc
        d = nd
        tx = ntx
        ty = nty
        current = parent ?: break
    }
    out.setAffine(a, b, c, d, tx, ty)
    if (!rootFound) rootOut?.setAffine(a, b, c, d, tx, ty)
    return true
}

private fun DoubleArray.setAffine(
    a: Double,
    b: Double,
    c: Double,
    d: Double,
    tx: Double,
    ty: Double,
) {
    this[0] = a
    this[1] = b
    this[2] = c
    this[3] = d
    this[4] = tx
    this[5] = ty
}

/**
 * Kotlin mirror of `hostWindowTransformFromAffine` (cpp/SmoothClipFlightGeometry.h)
 * for the carrier, which can only draw a uniform scale and a translation.
 * Window-space input itself is always classified by the shared C++.
 */
internal fun isUniformScaleTranslate(affine: DoubleArray): Boolean {
    val tolerance = 1e-6
    val a = affine[0]
    return affine.all { it.isFinite() } && abs(affine[1]) <= tolerance &&
        abs(affine[2]) <= tolerance &&
        abs(a - affine[3]) <= tolerance * max(1.0, abs(a)) && a > tolerance
}

/**
 * True while [view] or an ancestor runs a legacy view Animation: the fragment
 * enter/exit tweens of react-native-screens (and any other screen container
 * built on them). An animation that is set but not yet started counts, since
 * it starts on the next draw.
 */
internal fun isInScreenTransition(view: View): Boolean {
    var current: View? = view
    while (current != null) {
        val animation = current.animation
        if (animation != null && !animation.hasEnded()) return true
        current = current.parent as? View
    }
    return false
}

/**
 * The window's flight layer: the last child of `android.R.id.content`, above
 * every screen container (screen tweens and draw reordering all happen inside
 * the stack, and HWUI only sorts Z among siblings). Never hit-testable and
 * hidden from accessibility. Created on the first lift in a window and kept.
 */
internal class SmoothClipFlightLayer(context: Context) : FrameLayout(context) {
    init {
        clipChildren = false
        clipToPadding = false
        isClickable = false
        isFocusable = false
        descendantFocusability = FOCUS_BLOCK_DESCENDANTS
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        setWillNotDraw(true)
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean = false

    override fun onInterceptTouchEvent(event: MotionEvent): Boolean = false

    // Carriers cover the layer; their stages own the host size, so FrameLayout
    // never re-lays the flying content.
    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        for (index in 0 until childCount) {
            getChildAt(index).layout(0, 0, right - left, bottom - top)
        }
    }

    companion object {
        /** The layer of [host]'s window, created and brought to the front as needed. */
        fun obtain(host: View): SmoothClipFlightLayer? {
            val root = host.rootView as? ViewGroup ?: return null
            val content = root.findViewById<ViewGroup>(android.R.id.content) ?: root
            for (index in 0 until content.childCount) {
                val existing = content.getChildAt(index) as? SmoothClipFlightLayer ?: continue
                if (index != content.childCount - 1) existing.bringToFront()
                return existing
            }
            val layer = SmoothClipFlightLayer(content.context)
            content.addView(
                layer,
                LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
            )
            // Usable in this frame, before the next traversal measures it.
            layer.layout(
                content.paddingLeft,
                content.paddingTop,
                max(content.paddingLeft, content.width - content.paddingRight),
                max(content.paddingTop, content.height - content.paddingBottom),
            )
            return layer
        }
    }
}

/**
 * One airborne host. The carrier itself covers the whole flight layer and
 * carries the flight's opacity: a view with alpha < 1 and overlapping
 * rendering composites through an offscreen layer clipped to its own bounds,
 * so the host-sized presentation container (which keeps alpha 1 while
 * airborne) would cut the flying content to the host's slot. Inside, a
 * host-sized stage is drawn through the host's window transform captured at
 * lift (pivot 0, uniform scale, translation) and holds the host's
 * presentation container. Nothing in it is hit-testable.
 */
internal class SmoothClipFlightCarrier(context: Context) : ViewGroup(context) {
    var hostWidth = 0
        private set
    var hostHeight = 0
        private set

    /** Host-sized and transformed; the presentation container's parent. */
    internal val stage = Stage(context)

    internal inner class Stage(context: Context) : ViewGroup(context) {
        init {
            clipChildren = false
            clipToPadding = false
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            setWillNotDraw(true)
            pivotX = 0f
            pivotY = 0f
        }

        /** Takes [child] from a parent in the same window without detaching it. */
        fun adopt(child: View) {
            attachViewToParent(child, -1, child.layoutParams ?: generateDefaultLayoutParams())
            child.layout(0, 0, hostWidth, hostHeight)
            invalidate()
        }

        /** Gives [child] up for a parent in the same window, keeping it attached. */
        fun release(child: View) {
            endViewTransition(child)
            detachViewFromParent(child)
            invalidate()
        }

        override fun generateDefaultLayoutParams(): LayoutParams =
            LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)

        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            setMeasuredDimension(hostWidth, hostHeight)
        }

        override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
            for (index in 0 until childCount) getChildAt(index).layout(0, 0, hostWidth, hostHeight)
        }

        override fun dispatchTouchEvent(event: MotionEvent): Boolean = false

        override fun shouldDelayChildPressedState(): Boolean = false
    }

    init {
        clipChildren = false
        clipToPadding = false
        isClickable = false
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        setWillNotDraw(true)
        addView(stage)
    }

    /** The stage's uniform window scale. */
    val windowScale: Float
        get() = stage.scaleX

    fun holds(child: View): Boolean = child.parent === stage

    fun setHostSize(width: Int, height: Int) {
        hostWidth = width
        hostHeight = height
        stage.layout(0, 0, width, height)
        for (index in 0 until stage.childCount) {
            stage.getChildAt(index).layout(0, 0, width, height)
        }
    }

    fun setWindowTransform(scale: Float, translateX: Float, translateY: Float) {
        stage.scaleX = scale
        stage.scaleY = scale
        stage.translationX = translateX
        stage.translationY = translateY
    }

    /** Same window: moves [child] in without a window detach. */
    fun adopt(child: View) = stage.adopt(child)

    /** Same window: moves [child] out without a window detach. */
    fun release(child: View) = stage.release(child)

    /** Across windows (or into/out of a detached host): a real add. */
    fun addFlying(child: View) {
        stage.addView(child)
        child.layout(0, 0, hostWidth, hostHeight)
    }

    /** Across windows (or into a detached host): a real remove. */
    fun removeFlying(child: View) {
        stage.endViewTransition(child)
        child.clearAnimation()
        stage.removeView(child)
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(
            MeasureSpec.getSize(widthMeasureSpec),
            MeasureSpec.getSize(heightMeasureSpec),
        )
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        stage.layout(0, 0, hostWidth, hostHeight)
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean = false

    override fun shouldDelayChildPressedState(): Boolean = false
}

/**
 * Process-wide, main-thread-only flight bookkeeping: the tag -> target
 * registry, which tags are airborne (and so cover their targets), and the
 * retry of held landings: on the target changes that can end them, and on
 * every frame only while one waits on something no callback reports (a
 * screen transition, a deadline).
 */
internal object SmoothClipFlightTargets {
    private val targets = mutableListOf<WeakReference<SmoothClipFlightTarget>>()
    private val airborne = HashMap<String, MutableList<WeakReference<SmoothClipView>>>()
    private val holding = mutableListOf<WeakReference<SmoothClipHostFlight>>()
    private var retryPosted = false

    /** Milliseconds for the fallback deadline; tests drive it. */
    internal var clock: () -> Long = { SystemClock.uptimeMillis() }

    /** Posts the next held-landing retry; tests capture it. */
    internal var postFrame: (() -> Unit) -> Unit = { action ->
        Choreographer.getInstance().postFrameCallback { action() }
    }

    private fun prune() {
        targets.removeAll { it.get() == null }
        holding.removeAll { it.get() == null }
        val iterator = airborne.entries.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next()
            entry.value.removeAll { it.get() == null }
            if (entry.value.isEmpty()) iterator.remove()
        }
    }

    fun isAirborne(tag: String): Boolean =
        tag.isNotEmpty() && airborne[tag]?.any { it.get() != null } == true

    /** The most recently registered target with [tag] that is in a window. */
    fun attachedTarget(tag: String): SmoothClipFlightTarget? {
        if (tag.isEmpty()) return null
        for (index in targets.indices.reversed()) {
            val target = targets[index].get() ?: continue
            if (target.flightTag == tag && target.isAttachedToWindow) return target
        }
        return null
    }

    /** Whether a target with [tag] is mounted, in a window or not. */
    fun hasRegisteredTarget(tag: String): Boolean =
        tag.isNotEmpty() && targets.any { it.get()?.flightTag == tag }

    /**
     * The target's tag changed, or it left the registry. Held landings
     * re-check now, or on the next frame when it left from a window detach
     * ([retryNow] false; see [targetStateChanged]).
     */
    fun targetTagChanged(target: SmoothClipFlightTarget, oldTag: String, retryNow: Boolean = true) {
        prune()
        targets.removeAll { it.get() === target }
        if (target.flightTag.isNotEmpty()) targets += WeakReference(target)
        // A target that mounts while its flight is airborne (the route a
        // flight is heading to) is covered in the same mount, and that
        // flight has now seen its target.
        target.setFlightCovered(isAirborne(target.flightTag))
        airborne[target.flightTag]?.forEach { it.get()?.let { host -> host.flight.targetMounted() } }
        if (oldTag.isNotEmpty()) {
            airborne[oldTag]?.toList()?.forEach { it.get()?.flight?.targetLeft() }
        }
        if (!retryNow) {
            if (holding.isNotEmpty()) scheduleRetry()
            return
        }
        if (oldTag.isNotEmpty()) retryHolding(oldTag)
        retryHolding(target.flightTag)
    }

    /**
     * The target attached, detached or changed `ready`. A covering flight
     * hides it at once; held landings re-check now ([retryNow], a prop
     * change) or on the next frame (an attach or detach, which must not
     * reparent views while the window dispatch is walking them).
     */
    fun targetStateChanged(target: SmoothClipFlightTarget, retryNow: Boolean) {
        val tag = target.flightTag
        if (tag.isEmpty()) return
        if (isAirborne(tag) && !target.flightCovered) target.setFlightCovered(true)
        if (retryNow) {
            retryHolding(tag)
        } else if (holding.isNotEmpty()) {
            scheduleRetry()
        }
    }

    fun hostLifted(host: SmoothClipView, tag: String) {
        if (tag.isEmpty()) return
        prune()
        val hosts = airborne.getOrPut(tag) { mutableListOf() }
        if (hosts.none { it.get() === host }) hosts += WeakReference(host)
        for (reference in targets) {
            val target = reference.get() ?: continue
            if (target.flightTag == tag) target.setFlightCovered(true)
        }
    }

    fun hostLanded(host: SmoothClipView, tag: String) {
        if (tag.isEmpty()) return
        airborne[tag]?.removeAll { it.get() == null || it.get() === host }
        if (airborne[tag]?.isEmpty() == true) airborne.remove(tag)
        if (isAirborne(tag)) return
        for (reference in targets) {
            val target = reference.get() ?: continue
            // A dropped target stays covered until its exiting screen lets it go.
            if (target.flightTag == tag && !target.flightDropped) target.setFlightCovered(false)
        }
    }

    fun startHolding(flight: SmoothClipHostFlight) {
        if (holding.none { it.get() === flight }) holding += WeakReference(flight)
        if (flight.needsFrames) scheduleRetry()
    }

    fun stopHolding(flight: SmoothClipHostFlight) {
        holding.removeAll { it.get() == null || it.get() === flight }
    }

    private fun retryHolding(tag: String) {
        if (tag.isEmpty()) return
        for (reference in holding.toList()) {
            val flight = reference.get() ?: continue
            if (flight.tag == tag) flight.retryLanding()
        }
    }

    /**
     * Re-evaluates every held landing; those still waiting on a transition
     * or a deadline are retried next frame.
     */
    fun retryHeldLandings() {
        retryPosted = false
        prune()
        for (reference in holding.toList()) reference.get()?.retryLanding()
        if (holding.any { it.get()?.needsFrames == true }) scheduleRetry()
    }

    private fun scheduleRetry() {
        if (retryPosted) return
        retryPosted = true
        postFrame { retryHeldLandings() }
    }

    /** Test hook: forgets every target, airborne tag and held landing. */
    internal fun resetForTests() {
        targets.clear()
        airborne.clear()
        holding.clear()
        retryPosted = false
    }
}

/**
 * The flight state of one SmoothClipView with `flightEnabled`. The registry
 * drives it: [lift] when a run starts or an interaction begins, [runEnded]
 * when a run finishes or is cancelled. The landing itself (handoff, wait,
 * return, fallback) is decided and performed here, natively.
 */
internal class SmoothClipHostFlight(private val host: SmoothClipView) {
    var enabled = false
        private set
    var tag = ""
        private set
    private var carrier: SmoothClipFlightCarrier? = null
    private var holding = false

    /**
     * The held landing waits on something only a frame retry sees (a screen
     * transition, a deadline). One that waits only for its target's `ready`
     * is retried by the prop update, and by the target's attach, detach or
     * drop: polling it every frame would do nothing for as long as an image
     * loads.
     */
    private var holdPolls = false
    private var holdStartedMs = 0L

    /**
     * An interaction holds the lift: no run drives it, and the next run's
     * end lands it. See [targetLeft] for the one case it lands without one.
     */
    private var interactionHeld = false

    /**
     * The direction, decided at lift: the target with the tag was attached
     * and visible then, so the flight leaves it (the way back, or a
     * route-hosted flight leaving its card). A departing flight never hands
     * off; it returns to its host.
     */
    var isDeparting = false
        private set

    /** The last run to end finished (false: cancelled, which never hands off). */
    private var runFinished = true

    /**
     * A target with the tag was mounted at some point of this lift. A landing
     * flight that saw its target and has none to land on has lost it: its
     * route was popped mid-flight, or its screen never attached.
     */
    private var sawTarget = false

    /** A target with this flight's tag mounted while it is airborne. */
    internal fun targetMounted() {
        if (isLifted) sawTarget = true
    }

    /**
     * A departing flight returned while its target was still attached and in
     * a screen transition (a pop): the target stays covered until that
     * transition ends, so it never shows beside its own flight.
     */
    var isUncoverPending = false
        private set

    /**
     * Host -> window transform captured at lift, in pixels, in window space
     * as window-space input reads it (the React root's, see [viewToWindowAffine]).
     */
    var scale = 1.0
        private set
    var translateX = 0.0
        private set
    var translateY = 0.0
        private set

    /**
     * A held landing handed off outside a registry call: the registry must
     * now reset the host to its rest presentation and record the landing.
     */
    var onAsyncHandoff: (() -> Unit)? = null

    val isLifted: Boolean
        get() = carrier != null

    val isHolding: Boolean
        get() = holding

    /** The frame retry has work: a polling hold, or a pending uncover. */
    internal val needsFrames: Boolean
        get() = (holding && holdPolls) || isUncoverPending

    internal val carrierView: SmoothClipFlightCarrier?
        get() = carrier

    fun setEnabled(value: Boolean) {
        if (enabled == value) return
        enabled = value
        if (!value && isLifted) {
            // Turning flights off mid-air lands at once, in the host.
            returnToHost()
        }
    }

    fun setTag(value: String) {
        if (tag == value) return
        val oldTag = tag
        tag = value
        if (isLifted) {
            SmoothClipFlightTargets.hostLanded(host, oldTag)
            SmoothClipFlightTargets.hostLifted(host, value)
        } else if (isUncoverPending) {
            // The old tag's departed target no longer belongs to this host.
            isUncoverPending = false
            updateRetry()
            SmoothClipFlightTargets.hostLanded(host, oldTag)
        }
    }

    /**
     * Lifts the host into its window's flight layer (see FLIGHT_LIFT_*), for
     * a run, or for an [interaction] (beginInteraction).
     */
    fun lift(interaction: Boolean = false): Int {
        if (!enabled) return FLIGHT_LIFT_NONE
        if (isLifted) {
            // A new run or an interaction takes the airborne content over:
            // a held landing stops waiting (an interaction holds the lift
            // until the next run ends, or the host is lost).
            holding = false
            interactionHeld = interaction
            updateRetry()
            return FLIGHT_LIFT_CONTINUED
        }
        if (!host.isAttachedToWindow || host.width <= 0 || host.height <= 0) {
            return FLIGHT_LIFT_NONE
        }
        // Scratch for this lift only: a host that never flies keeps none.
        val affine = DoubleArray(6)
        val windowSpaceAffine = DoubleArray(6)
        if (!viewToWindowAffine(host, affine, windowSpaceAffine) ||
            !isUniformScaleTranslate(affine)
        ) {
            return FLIGHT_LIFT_NONE
        }
        val layer = SmoothClipFlightLayer.obtain(host) ?: return FLIGHT_LIFT_NONE
        val layerAffine = DoubleArray(6)
        if (!viewToWindowAffine(layer, layerAffine)) return FLIGHT_LIFT_NONE
        val nextCarrier = SmoothClipFlightCarrier(host.context)
        layer.addView(
            nextCarrier,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
        nextCarrier.layout(0, 0, layer.width, layer.height)
        nextCarrier.setHostSize(host.width, host.height)
        // The layer sits unscaled at its window origin (the content view).
        nextCarrier.setWindowTransform(
            affine[0].toFloat(),
            (affine[4] - layerAffine[4]).toFloat(),
            (affine[5] - layerAffine[5]).toFloat(),
        )
        // Window-space input reads the same transform from the React root.
        scale = windowSpaceAffine[0]
        translateX = windowSpaceAffine[4]
        translateY = windowSpaceAffine[5]
        // The direction: decided before this lift covers the target.
        val departed = SmoothClipFlightTargets.attachedTarget(tag)
        isDeparting = departed != null && !departed.flightCovered && departed.isShown
        sawTarget = SmoothClipFlightTargets.hasRegisteredTarget(tag)
        interactionHeld = interaction
        // This lift covers the tag's targets now; a departed target's
        // pending uncover is this lift's to finish.
        isUncoverPending = false
        updateRetry()
        host.liftPresentationInto(nextCarrier)
        carrier = nextCarrier
        SmoothClipFlightTargets.hostLifted(host, tag)
        host.flightStateChanged()
        return FLIGHT_LIFT_NEW
    }

    /**
     * The run driving the lifted content ended: [finished], or cancelled
     * (which never hands off).
     */
    fun runEnded(finished: Boolean): Int {
        if (!isLifted) return FLIGHT_LAND_NONE
        interactionHeld = false
        runFinished = finished
        holdStartedMs = SmoothClipFlightTargets.clock()
        return evaluateLanding(synchronous = true)
    }

    /**
     * A held landing re-checks its cases (target, ready, transition, attach);
     * a pending uncover checks its departed target's transition.
     */
    fun retryLanding() {
        if (!isLifted) {
            holding = false
            if (isUncoverPending) finishPendingUncover() else updateRetry()
            return
        }
        if (!holding) {
            updateRetry()
            return
        }
        evaluateLanding(synchronous = false)
    }

    private fun evaluateLanding(synchronous: Boolean): Int {
        if (!runFinished) {
            // Cancelled: never hand off. Back into the host, where it is.
            returnToHost()
            return FLIGHT_LAND_RETURNED
        }
        val withinDeadline =
            SmoothClipFlightTargets.clock() - holdStartedMs < FLIGHT_FALLBACK_MS
        if (!isDeparting) {
            val target = SmoothClipFlightTargets.attachedTarget(tag)
            if (target != null) {
                if (target.flightReady && target.isSettled()) {
                    handOff()
                    if (!synchronous) onAsyncHandoff?.invoke()
                    return FLIGHT_LAND_HANDOFF
                }
                // Not ready: its `ready` update retries, no frame needs to.
                hold(poll = target.flightReady)
                return FLIGHT_LAND_HELD
            }
            if (withinDeadline && SmoothClipFlightTargets.hasRegisteredTarget(tag)) {
                // Android-only wait: react-native-screens attaches a pushed screen
                // one message after its Fabric mount, so a target can be mounted
                // and not yet in a window when a short flight ends. It counts as
                // arriving, for the fallback deadline at most.
                hold()
                return FLIGHT_LAND_HELD
            }
        }
        // Departing, or no target: back into the host once it is on screen.
        if (host.isAttachedToWindow) {
            if (!isInScreenTransition(host)) return landInHost(synchronous)
            hold()
            return FLIGHT_LAND_HELD
        }
        if (!withinDeadline) return landInHost(synchronous)
        hold()
        return FLIGHT_LAND_HELD
    }

    /**
     * Back into the host. A departing flight, or one that never had a target,
     * returns where the run left it. A landing flight that saw its target and
     * has none attached now has lost it (the route was popped mid-flight and
     * nothing flew the host home, or its screen never attached): it arrived
     * somewhere that is gone, so it lands as a handoff with nothing to
     * reveal, and the registry puts the host back at rest. Returned where it
     * landed, the host would stay at the destination frame on its own screen.
     */
    private fun landInHost(synchronous: Boolean): Int {
        if (!isDeparting && sawTarget) {
            handOff()
            if (!synchronous) onAsyncHandoff?.invoke()
            return FLIGHT_LAND_HANDOFF
        }
        returnToHost()
        return FLIGHT_LAND_RETURNED
    }

    /** The paired target is attached and visible: a later run starts from the landing. */
    fun wayBackAvailable(): Boolean {
        if (!enabled || tag.isEmpty()) return false
        val target = SmoothClipFlightTargets.attachedTarget(tag) ?: return false
        return !target.flightCovered && target.isShown
    }

    /**
     * The host was deleted or dropped while airborne: land at once. A
     * pending uncover ends too: nothing will report its target's transition.
     */
    fun hostLost() {
        if (isLifted) {
            land(keepDepartedCovered = false)
        } else if (isUncoverPending) {
            isUncoverPending = false
            updateRetry()
            SmoothClipFlightTargets.hostLanded(host, tag)
        }
    }

    private fun hold(poll: Boolean = true) {
        holding = true
        holdPolls = poll
        updateRetry()
    }

    /**
     * The tag lost a target. An interaction that departed from a target that
     * has now left the registry (its route was popped, with the code driving
     * the interaction: a route that follows its own dismissal) has nothing
     * left to start the run that would end it. It lands as a landing flight
     * that lost its target, with the host back at rest, from the next frame
     * (this can run inside a window detach). Held, it would stay above every
     * screen for good.
     */
    internal fun targetLeft() {
        if (!isLifted || !interactionHeld || !isDeparting ||
            SmoothClipFlightTargets.hasRegisteredTarget(tag)
        ) {
            return
        }
        interactionHeld = false
        isDeparting = false
        sawTarget = true
        runFinished = true
        holdStartedMs = SmoothClipFlightTargets.clock()
        hold()
    }

    /**
     * Registers this flight for the per-frame retry while a landing is held
     * or a departed target waits to be uncovered, and unregisters it after.
     */
    private fun updateRetry() {
        if (holding || isUncoverPending) {
            SmoothClipFlightTargets.startHolding(this)
        } else {
            SmoothClipFlightTargets.stopHolding(this)
        }
    }

    private fun handOff() {
        // One transaction: reveal the target, put the container back, drop
        // the carrier. The registry's reset to rest follows synchronously.
        land(keepDepartedCovered = false)
    }

    private fun returnToHost() {
        land(keepDepartedCovered = true)
    }

    /**
     * Ends the lift. A departing flight whose target is still attached and in
     * a screen transition (a pop) leaves that target covered until the
     * transition ends ([finishPendingUncover]); otherwise the tag's targets
     * are revealed now.
     */
    private fun land(keepDepartedCovered: Boolean) {
        val current = carrier ?: return
        holding = false
        val departed = if (keepDepartedCovered && isDeparting) {
            SmoothClipFlightTargets.attachedTarget(tag)
        } else {
            null
        }
        isUncoverPending = departed != null && isInScreenTransition(departed)
        updateRetry()
        if (!isUncoverPending) SmoothClipFlightTargets.hostLanded(host, tag)
        carrier = null
        host.returnPresentationFromFlight(current)
        (current.parent as? ViewGroup)?.removeView(current)
        host.flightStateChanged()
    }

    /** The departed target's transition ended (or it left): reveal it. */
    private fun finishPendingUncover() {
        val departed = SmoothClipFlightTargets.attachedTarget(tag)
        if (departed != null && isInScreenTransition(departed)) return
        isUncoverPending = false
        updateRetry()
        SmoothClipFlightTargets.hostLanded(host, tag)
    }

    /** Keeps the stage host-sized when Fabric re-lays the host mid-flight. */
    fun hostSizeChanged(width: Int, height: Int) {
        carrier?.setHostSize(width, height)
    }
}
