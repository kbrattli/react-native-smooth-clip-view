package com.smoothclipview

import android.app.Activity
import android.content.Context
import android.os.Looper
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.animation.AlphaAnimation
import com.facebook.react.bridge.JavaOnlyMap
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.internal.featureflags.ReactNativeFeatureFlagsForTests
import com.facebook.react.uimanager.BackgroundStyleApplicator
import com.facebook.react.uimanager.DisplayMetricsHolder
import com.facebook.react.uimanager.LengthPercentage
import com.facebook.react.uimanager.LengthPercentageType
import com.facebook.react.uimanager.ReactStylesDiffMap
import com.facebook.react.uimanager.RootView
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.style.BorderRadiusProp
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.Mockito.mock
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * The Android flight layer and its lift/land state machine, driven the way
 * the registry drives it (flightLift / flightRunEnded). The registry half of
 * a handoff (reset to rest, landed record) is C++ and is not reachable from
 * the JVM; these tests pin the view half and the codes the registry acts on.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class SmoothClipFlightRobolectricTest {
    /** A container that keeps the frames tests give its children. */
    private open class Screen(context: Context) : ViewGroup(context) {
        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            setMeasuredDimension(
                MeasureSpec.getSize(widthMeasureSpec),
                MeasureSpec.getSize(heightMeasureSpec),
            )
        }

        override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) = Unit
    }

    /** A React root (ReactRootView, ReactSurfaceView or a Modal's dialog root). */
    private class ReactRoot(context: Context) : Screen(context), RootView {
        override fun onChildStartedNativeGesture(childView: View?, ev: MotionEvent) = Unit

        override fun onChildEndedNativeGesture(childView: View, ev: MotionEvent) = Unit

        override fun handleException(t: Throwable) = throw t
    }

    private lateinit var activity: Activity
    private lateinit var themed: ThemedReactContext
    private lateinit var root: Screen
    private lateinit var listScreen: Screen
    private lateinit var detailScreen: Screen
    private lateinit var host: SmoothClipView
    private var now = 1_000L
    private val frames = mutableListOf<() -> Unit>()
    private var asyncHandoffs = 0

    @Before
    fun setUp() {
        ReactNativeFeatureFlagsForTests.setUp()
        SmoothClipFlightTargets.resetForTests()
        SmoothClipFlightTargets.clock = { now }
        SmoothClipFlightTargets.postFrame = { frames += it }
        activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        DisplayMetricsHolder.setScreenDisplayMetrics(activity.resources.displayMetrics)
        themed = ThemedReactContext(
            mock(ReactApplicationContext::class.java), activity, null, -1,
        )
        root = Screen(activity)
        activity.setContentView(root)
        idle()
        markWindowVisible()
        listScreen = Screen(activity)
        root.addView(listScreen)
        listScreen.layout(0, 0, 300, 600)
        detailScreen = Screen(activity)
        root.addView(detailScreen)
        detailScreen.layout(0, 0, 300, 600)
        host = SmoothClipView(themed)
        listScreen.addView(host)
        host.layout(20, 40, 120, 140)
        host.flight.onAsyncHandoff = { asyncHandoffs += 1 }
        host.flight.setEnabled(true)
        host.flight.setTag("hero")
    }

    @After
    fun tearDown() {
        SmoothClipFlightTargets.resetForTests()
    }

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    /**
     * Robolectric attaches the activity's views but never reports its window
     * visible (getWindowVisibility() stays GONE). Every view of the window
     * shares one AttachInfo; mark it visible as a shown window would be.
     */
    private fun markWindowVisible() {
        val attachInfo = View::class.java.getDeclaredField("mAttachInfo")
            .apply { isAccessible = true }
            .get(activity.window.decorView)
        attachInfo.javaClass.getDeclaredField("mWindowVisibility")
            .apply { isAccessible = true }
            .setInt(attachInfo, View.VISIBLE)
        assertEquals(View.VISIBLE, root.windowVisibility)
    }

    private fun content(): ViewGroup = activity.findViewById(android.R.id.content)

    private fun layer(): SmoothClipFlightLayer? =
        (0 until content().childCount)
            .map { content().getChildAt(it) }
            .filterIsInstance<SmoothClipFlightLayer>()
            .firstOrNull()

    private fun carrier(): SmoothClipFlightCarrier? = host.flight.carrierView

    private fun locationInWindow(view: View): IntArray =
        IntArray(2).also { view.getLocationInWindow(it) }

    /** A target Fabric mounted, not yet in a window (a pushed screen before its attach). */
    private fun registerTarget(tag: String, ready: Boolean = true): SmoothClipFlightTarget {
        val target = SmoothClipFlightTarget(themed)
        target.setPendingTag(tag)
        target.setPendingReady(ready)
        target.commitProps()
        target.contentContainer.addView(View(themed))
        return target
    }

    private fun attachTarget(target: SmoothClipFlightTarget) {
        detailScreen.addView(target)
        target.layout(0, 100, 300, 400)
    }

    /**
     * A target attached in the detail screen. Mounted before a lift, it is
     * visible then, so that flight departs from it; mounted while airborne,
     * the flight lands on it.
     */
    private fun mountTarget(tag: String, ready: Boolean = true): SmoothClipFlightTarget =
        registerTarget(tag, ready).also { attachTarget(it) }

    private fun runFrames() {
        val pending = frames.toList()
        frames.clear()
        pending.forEach { it() }
    }

    /**
     * A pop as react-native-screens runs it: the exiting screen starts a view
     * transition on its descendants, so it keeps drawing them through its
     * exit animation, then Fabric removes the target and drops it.
     */
    private fun popTarget(target: SmoothClipFlightTarget) {
        detailScreen.startViewTransition(target)
        detailScreen.removeView(target)
        SmoothClipFlightTargetManager().onDropViewInstance(target)
    }

    /** The exit ends: react-native-screens ends the transitions. */
    private fun finishPop(target: SmoothClipFlightTarget) {
        detailScreen.clearAnimation()
        detailScreen.endViewTransition(target)
        assertFalse(target.isAttachedToWindow)
    }

    // --- Window space -------------------------------------------------------

    @Test
    fun windowAffineIsIdentityForAViewAtTheOrigin() {
        val lone = Screen(activity)
        lone.layout(0, 0, 50, 50)
        val affine = DoubleArray(6)
        assertTrue(viewToWindowAffine(lone, affine))
        assertEquals(listOf(1.0, 0.0, 0.0, 1.0, 0.0, 0.0), affine.toList())
        assertTrue(isUniformScaleTranslate(affine))
    }

    @Test
    fun windowAffineAddsLayoutTranslationAndParentScroll() {
        val top = Screen(activity)
        top.layout(0, 0, 500, 500)
        val middle = Screen(activity)
        top.addView(middle)
        middle.layout(20, 40, 400, 400)
        middle.scrollTo(0, 10)
        val leaf = Screen(activity)
        middle.addView(leaf)
        leaf.layout(5, 6, 55, 56)
        leaf.translationX = 3f
        val affine = DoubleArray(6)
        assertTrue(viewToWindowAffine(leaf, affine))
        assertEquals(1.0, affine[0], 1e-9)
        assertEquals(28.0, affine[4], 1e-6)
        assertEquals(36.0, affine[5], 1e-6)
        assertTrue(isUniformScaleTranslate(affine))
    }

    @Test
    fun windowAffineCarriesAnAncestorsUniformScale() {
        val top = Screen(activity)
        top.layout(0, 0, 500, 500)
        val scaled = Screen(activity)
        top.addView(scaled)
        scaled.layout(100, 0, 400, 300)
        scaled.pivotX = 0f
        scaled.pivotY = 0f
        scaled.scaleX = 0.9f
        scaled.scaleY = 0.9f
        val leaf = Screen(activity)
        scaled.addView(leaf)
        leaf.layout(50, 20, 150, 120)
        val affine = DoubleArray(6)
        assertTrue(viewToWindowAffine(leaf, affine))
        assertEquals(0.9, affine[0], 1e-6)
        assertEquals(0.9, affine[3], 1e-6)
        assertEquals(0.0, affine[1], 1e-9)
        assertEquals(0.0, affine[2], 1e-9)
        assertEquals(100.0 + 0.9 * 50.0, affine[4], 1e-4)
        assertEquals(0.9 * 20.0, affine[5], 1e-4)
        assertTrue(isUniformScaleTranslate(affine))
    }

    @Test
    fun rotatedAncestorIsNotAUniformScaleAndDoesNotLift() {
        listScreen.rotation = 30f
        val affine = DoubleArray(6)
        assertTrue(viewToWindowAffine(host, affine))
        assertFalse(isUniformScaleTranslate(affine))
        // The registry classifies this affine with the shared
        // hostWindowTransformFromAffine, which rejects it the same way.
        val reported = host.flightWindowTransform()!!
        assertTrue(kotlin.math.abs(reported[1]) > 0.1)
        assertEquals(FLIGHT_LIFT_NONE, host.flightLift())
        assertNull(carrier())
    }

    @Test
    @Config(qualifiers = "xhdpi")
    fun windowTransformIsReportedInDip() {
        val density = host.densityScale()
        assertEquals(2.0, density, 1e-6)
        val location = locationInWindow(host)
        val values = host.flightWindowTransform()!!
        assertEquals(8, values.size)
        assertEquals(1.0, values[0], 1e-9)
        assertEquals(location[0] / density, values[4], 1e-6)
        assertEquals(location[1] / density, values[5], 1e-6)
        assertEquals(100 / density, values[6], 1e-9)
        assertEquals(100 / density, values[7], 1e-9)
        // Airborne hosts report the transform captured at lift, even after
        // their screen moves away.
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        listScreen.translationX = -300f
        val lifted = host.flightWindowTransform()!!
        assertEquals(location[0] / density, lifted[4], 1e-6)
    }

    @Test
    @Config(qualifiers = "xhdpi")
    fun windowSpaceIsTheReactRootsSpace() {
        // Without edge-to-edge the React root starts below the status bar.
        // Layout, safe-area insets, measure() and measureInWindow (whose
        // viewport offset then drops the status bar) are all relative to it.
        val reactRoot = ReactRoot(activity)
        root.addView(reactRoot)
        reactRoot.layout(0, 63, 300, 663)
        val screen = Screen(activity)
        reactRoot.addView(screen)
        screen.layout(0, 0, 300, 600)
        val card = SmoothClipView(themed)
        screen.addView(card)
        card.layout(20, 40, 120, 140)
        card.flight.setEnabled(true)
        val density = card.densityScale()
        val values = card.flightWindowTransform()!!
        assertEquals(20 / density, values[4], 1e-6)
        assertEquals(40 / density, values[5], 1e-6)
        // At lift too. The carrier still draws on the card's own pixels.
        val before = locationInWindow(card.contentContainer)
        assertEquals(FLIGHT_LIFT_NEW, card.flightLift())
        assertEquals(before.toList(), locationInWindow(card.contentContainer).toList())
        val lifted = card.flightWindowTransform()!!
        assertEquals(1.0, lifted[0], 1e-9)
        assertEquals(20 / density, lifted[4], 1e-6)
        assertEquals(40 / density, lifted[5], 1e-6)
    }

    // --- Lift ---------------------------------------------------------------

    @Test
    fun liftMovesTheContainerIntoTheTopmostFlightLayer() {
        val before = locationInWindow(host.contentContainer)
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        val layer = layer()
        assertNotNull(layer)
        assertSame(layer, content().getChildAt(content().childCount - 1))
        assertEquals(
            View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS,
            layer!!.importantForAccessibility,
        )
        val carrier = carrier()!!
        assertSame(layer, carrier.parent)
        assertTrue(carrier.holds(host.presentationContainer))
        // The carrier covers the layer; its stage is host-sized.
        assertEquals(layer.width, carrier.width)
        assertEquals(layer.height, carrier.height)
        // Moved within the window: never detached.
        assertTrue(host.presentationContainer.isAttachedToWindow)
        assertEquals(100, carrier.hostWidth)
        assertEquals(100, carrier.hostHeight)
        // Drawn through the host's window transform: same pixels as before.
        assertEquals(before.toList(), locationInWindow(host.contentContainer).toList())
        // Nothing airborne takes touches.
        val down = MotionEvent.obtain(0L, 0L, MotionEvent.ACTION_DOWN, 50f, 50f, 0)
        assertFalse(layer.dispatchTouchEvent(down))
        assertFalse(host.dispatchTouchEvent(down))
        // A second run continues the same lift.
        assertEquals(FLIGHT_LIFT_CONTINUED, host.flightLift())
        assertSame(carrier, carrier())
    }

    @Test
    fun liftDrawsThroughAScaledAncestor() {
        listScreen.pivotX = 0f
        listScreen.pivotY = 0f
        listScreen.scaleX = 0.9f
        listScreen.scaleY = 0.9f
        val before = locationInWindow(host.contentContainer)
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        assertEquals(0.9f, carrier()!!.windowScale, 1e-6f)
        assertEquals(before.toList(), locationInWindow(host.contentContainer).toList())
    }

    @Test
    fun airborneOpacityIsCompositedByTheLayerSizedCarrier() {
        host.setClipPresentationPx(
            0f, 0f, 100f, 100f, 0f, 0f, 0f, 0f, CLIP_CURVE_CIRCULAR,
            0f, 0f, 1f, opacity = 0.5f,
        )
        assertEquals(0.5f, host.presentationContainer.alpha)
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        // A host-sized offscreen layer would clip content flying outside the
        // host's slot, so the container stays opaque while airborne.
        assertEquals(1f, host.presentationContainer.alpha)
        assertEquals(0.5f, carrier()!!.alpha)
        host.setClipPresentationPx(
            400f, 300f, 500f, 400f, 0f, 0f, 0f, 0f, CLIP_CURVE_CIRCULAR,
            400f, 300f, 1f, opacity = 0.25f,
        )
        assertEquals(1f, host.presentationContainer.alpha)
        assertEquals(0.25f, carrier()!!.alpha)
        assertEquals(FLIGHT_LAND_RETURNED, host.flightRunEnded(finished = true))
        assertEquals(0.25f, host.presentationContainer.alpha)
    }

    @Test
    fun disabledFlightNeverLifts() {
        host.flight.setEnabled(false)
        assertEquals(FLIGHT_LIFT_NONE, host.flightLift())
        assertEquals(FLIGHT_LAND_NONE, host.flightRunEnded(finished = true))
        assertSame(host, host.presentationContainer.parent)
    }

    // --- Land ---------------------------------------------------------------

    @Test
    fun targetIsHiddenAtLiftAndRevealedAtTheHandoff() {
        // Mounted, not yet attached: the flight lands on it.
        val target = registerTarget("hero")
        assertFalse(target.flightCovered)
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        assertFalse(host.flight.isDeparting)
        assertTrue(target.flightCovered)
        attachTarget(target)
        assertTrue(target.flightCovered)
        assertEquals(0f, target.contentContainer.alpha)
        assertEquals(
            View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS,
            target.contentContainer.importantForAccessibility,
        )
        // The target's own view (its React styles) is never touched.
        assertEquals(1f, target.alpha)
        assertFalse(host.flightWayBackAvailable())

        // Handoff: the registry resets the host to rest on this code.
        assertEquals(FLIGHT_LAND_HANDOFF, host.flightRunEnded(finished = true))
        assertFalse(target.flightCovered)
        assertEquals(1f, target.contentContainer.alpha)
        assertSame(host, host.presentationContainer.parent)
        assertTrue(host.presentationContainer.isAttachedToWindow)
        assertNull(carrier())
        assertEquals(0, layer()!!.childCount)
        // Synchronous handoffs are completed by the registry call itself.
        assertEquals(0, asyncHandoffs)

        // The way back: the paired target is on screen, so the next run starts
        // from the landing; its lift hides the target again.
        assertTrue(host.flightWayBackAvailable())
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        assertTrue(target.flightCovered)
        assertFalse(host.flightWayBackAvailable())
        // It departs from the target: when it ends, it never hands off to it,
        // although the target is attached, ready and out of transition.
        assertTrue(host.flight.isDeparting)
        assertEquals(FLIGHT_LAND_RETURNED, host.flightRunEnded(finished = true))
        assertFalse(target.flightCovered)
        assertSame(host, host.presentationContainer.parent)
        assertNull(carrier())
        assertEquals(0, asyncHandoffs)
    }

    @Test
    fun notReadyTargetHoldsTheLandingUntilReady() {
        val manager = SmoothClipFlightTargetManager()
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        val target = mountTarget("hero", ready = false)
        assertEquals(FLIGHT_LAND_HELD, host.flightRunEnded(finished = true))
        assertTrue(host.flight.isHolding)
        assertTrue(target.flightCovered)
        assertNotNull(carrier())
        // Retries keep holding while the target is not ready.
        runFrames()
        assertTrue(host.flight.isHolding)
        assertEquals(0, asyncHandoffs)

        // `ready` arrives through the view manager (codegen delegate): the
        // landing hands off in the same mount, outside any registry call.
        manager.updateProperties(
            target,
            ReactStylesDiffMap(JavaOnlyMap.of("ready", true)),
        )
        assertTrue(target.flightReady)
        assertFalse(target.flightCovered)
        assertSame(host, host.presentationContainer.parent)
        assertNull(carrier())
        assertFalse(host.flight.isHolding)
        assertEquals(1, asyncHandoffs)
    }

    @Test
    fun targetMountedWhileAirborneMountsHidden() {
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        val target = SmoothClipFlightTarget(themed)
        target.setPendingTag("hero")
        target.commitProps()
        // Covered before it is even attached, so it never shows beside the flight.
        assertFalse(target.isAttachedToWindow)
        assertTrue(target.flightCovered)
        detailScreen.addView(target)
        target.layout(0, 0, 100, 100)
        assertTrue(target.flightCovered)
        // A target with another tag is not covered.
        val other = mountTarget("other")
        assertFalse(other.flightCovered)
        assertEquals(FLIGHT_LAND_HANDOFF, host.flightRunEnded(finished = true))
        assertFalse(target.flightCovered)
    }

    @Test
    fun targetInAScreenTransitionHoldsUntilTheTransitionEnds() {
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        val target = mountTarget("hero")
        val enter = AlphaAnimation(0f, 1f).apply { duration = 300 }
        detailScreen.animation = enter
        assertEquals(FLIGHT_LAND_HELD, host.flightRunEnded(finished = true))
        runFrames()
        assertTrue(host.flight.isHolding)
        detailScreen.clearAnimation()
        runFrames()
        assertFalse(host.flight.isHolding)
        assertFalse(target.flightCovered)
        assertSame(host, host.presentationContainer.parent)
        assertEquals(1, asyncHandoffs)
    }

    @Test
    fun withoutATargetTheContentReturnsToTheAttachedHost() {
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        assertEquals(FLIGHT_LAND_RETURNED, host.flightRunEnded(finished = true))
        assertSame(host, host.presentationContainer.parent)
        assertTrue(host.presentationContainer.isAttachedToWindow)
        assertNull(carrier())
        assertFalse(host.flightWayBackAvailable())
    }

    @Test
    fun detachedHostStaysDisplayableAndFallsBackAfter300Ms() {
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        // The covered list screen detaches mid-flight (react-native-screens
        // removes covered screens): not host loss.
        root.removeView(listScreen)
        assertFalse(host.isAttachedToWindow)
        assertTrue(host.isHostLifecycleVisible())
        assertTrue(host.presentationContainer.isAttachedToWindow)

        assertEquals(FLIGHT_LAND_HELD, host.flightRunEnded(finished = true))
        now += FLIGHT_FALLBACK_MS - 1
        runFrames()
        assertTrue(host.flight.isHolding)
        assertNotNull(carrier())
        now += 1
        runFrames()
        assertFalse(host.flight.isHolding)
        assertNull(carrier())
        assertSame(host, host.presentationContainer.parent)
        // Back in a detached host: out of the window with it.
        assertFalse(host.presentationContainer.isAttachedToWindow)
        assertFalse(host.isHostLifecycleVisible())
        // A fallback is a return: no reset, no async handoff.
        assertEquals(0, asyncHandoffs)
    }

    @Test
    fun detachedHostThatReattachesTakesItsContentBack() {
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        root.removeView(listScreen)
        assertEquals(FLIGHT_LAND_HELD, host.flightRunEnded(finished = true))
        root.addView(listScreen)
        listScreen.layout(0, 0, 300, 600)
        assertTrue(host.isAttachedToWindow)
        runFrames()
        assertNull(carrier())
        assertSame(host, host.presentationContainer.parent)
        assertTrue(host.presentationContainer.isAttachedToWindow)
    }

    @Test
    fun targetMountedButNotYetInAWindowIsWaitedForUntilTheDeadline() {
        // react-native-screens attaches a pushed screen one message after the
        // Fabric mount: the target is registered, not yet attached.
        val target = SmoothClipFlightTarget(themed)
        target.setPendingTag("hero")
        target.commitProps()
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        assertTrue(target.flightCovered)
        assertEquals(FLIGHT_LAND_HELD, host.flightRunEnded(finished = true))
        detailScreen.addView(target)
        target.layout(0, 0, 100, 100)
        runFrames()
        assertFalse(host.flight.isHolding)
        assertFalse(target.flightCovered)
        assertSame(host, host.presentationContainer.parent)
        assertEquals(1, asyncHandoffs)
    }

    @Test
    fun aTargetThatNeverAttachesStopsHoldingAtTheDeadline() {
        val target = SmoothClipFlightTarget(themed)
        target.setPendingTag("hero")
        target.commitProps()
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        assertEquals(FLIGHT_LAND_HELD, host.flightRunEnded(finished = true))
        now += FLIGHT_FALLBACK_MS
        runFrames()
        // The host is attached and the stale target is uncovered. The flight
        // saw its target and has none to land on: it lands as a handoff with
        // nothing to reveal, so the registry puts the host back at rest.
        assertFalse(host.flight.isHolding)
        assertSame(host, host.presentationContainer.parent)
        assertFalse(target.flightCovered)
        assertEquals(1, asyncHandoffs)
    }

    @Test
    fun aLandingFlightThatLostItsTargetLandsAsAHandoff() {
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        // The route mounts while the card flies: its target mounts covered.
        val target = mountTarget("hero")
        assertTrue(target.flightCovered)
        // The route is popped before the flight lands, and nothing flies the
        // card home: the target leaves the window and Fabric drops it.
        detailScreen.removeView(target)
        SmoothClipFlightTargetManager().onDropViewInstance(target)
        // Not a return where it landed (the card would stay at the
        // destination frame over the list): a handoff, back at rest.
        assertEquals(FLIGHT_LAND_HANDOFF, host.flightRunEnded(finished = true))
        assertSame(host, host.presentationContainer.parent)
        assertNull(carrier())
        assertFalse(host.flight.isHolding)
    }

    @Test
    fun aFlightWhoseTargetNeverMountedReturnsWhereItLanded() {
        // A target with another tag is not this flight's.
        mountTarget("other")
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        assertEquals(FLIGHT_LAND_RETURNED, host.flightRunEnded(finished = true))
        assertSame(host, host.presentationContainer.parent)
    }

    @Test
    fun aNewRunWhileHeldContinuesTheLift() {
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        mountTarget("hero", ready = false)
        assertEquals(FLIGHT_LAND_HELD, host.flightRunEnded(finished = true))
        val carrier = carrier()
        assertEquals(FLIGHT_LIFT_CONTINUED, host.flightLift())
        assertFalse(host.flight.isHolding)
        assertSame(carrier, carrier())
    }

    @Test
    fun hostLossMidFlightLandsAtOnce() {
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        val target = mountTarget("hero")
        assertTrue(target.flightCovered)
        listScreen.removeView(host)
        SmoothClipViewManager().onDropViewInstance(host)
        assertNull(carrier())
        assertEquals(0, layer()!!.childCount)
        assertFalse(target.flightCovered)
        assertSame(host, host.presentationContainer.parent)
        assertFalse(SmoothClipFlightTargets.isAirborne("hero"))
    }

    @Test
    fun droppedTargetLeavesTheRegistry() {
        val manager = SmoothClipFlightTargetManager()
        val target = mountTarget("hero")
        assertSame(target, SmoothClipFlightTargets.attachedTarget("hero"))
        detailScreen.removeView(target)
        manager.onDropViewInstance(target)
        assertNull(SmoothClipFlightTargets.attachedTarget("hero"))
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        assertEquals(FLIGHT_LAND_RETURNED, host.flightRunEnded(finished = true))
    }

    @Test
    fun targetChildrenMountIntoTheInternalContainer() {
        val manager = SmoothClipFlightTargetManager()
        val target = SmoothClipFlightTarget(themed)
        val child = View(themed)
        manager.addView(target, child, 0)
        assertEquals(1, manager.getChildCount(target))
        assertSame(child, manager.getChildAt(target, 0))
        assertSame(target.contentContainer, child.parent)
        target.layout(0, 0, 80, 60)
        assertEquals(80, target.contentContainer.width)
        assertEquals(60, target.contentContainer.height)
        manager.removeViewAt(target, 0)
        assertEquals(0, manager.getChildCount(target))
    }

    @Test
    fun flightPropsReachTheHostThroughTheViewManager() {
        val manager = SmoothClipViewManager()
        val other = SmoothClipView(themed)
        manager.updateProperties(
            other,
            ReactStylesDiffMap(JavaOnlyMap.of("flightEnabled", true, "flightTag", "card")),
        )
        assertTrue(other.flight.enabled)
        assertEquals("card", other.flight.tag)
        manager.updateProperties(
            other,
            ReactStylesDiffMap(JavaOnlyMap.of("flightTag", null)),
        )
        assertEquals("", other.flight.tag)
    }

    @Test
    fun retaggingAnAirborneHostMovesTheCover() {
        val hero = mountTarget("hero")
        val card = mountTarget("card")
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        assertTrue(hero.flightCovered)
        host.flight.setTag("card")
        assertFalse(hero.flightCovered)
        assertTrue(card.flightCovered)
    }

    // --- Clarified rules (flight-spec.md) ------------------------------------

    @Test
    fun aDepartingFlightKeepsItsTargetCoveredUntilItsTransitionEnds() {
        // A pop: the flight leaves the detail target, whose screen is still
        // running its exit animation when the flight returns to the card.
        val target = mountTarget("hero")
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        assertTrue(host.flight.isDeparting)
        assertTrue(target.flightCovered)
        detailScreen.animation = AlphaAnimation(1f, 0f).apply { duration = 300 }
        assertEquals(FLIGHT_LAND_RETURNED, host.flightRunEnded(finished = true))
        assertSame(host, host.presentationContainer.parent)
        assertNull(carrier())
        // Revealing it now would show it beside its own flight.
        assertTrue(host.flight.isUncoverPending)
        assertTrue(target.flightCovered)
        runFrames()
        assertTrue(target.flightCovered)
        detailScreen.clearAnimation()
        runFrames()
        assertFalse(host.flight.isUncoverPending)
        assertFalse(target.flightCovered)
        assertFalse(SmoothClipFlightTargets.isAirborne("hero"))
        assertEquals(0, asyncHandoffs)
    }

    @Test
    fun aDepartedTargetThatLeavesTheWindowIsUncovered() {
        val target = mountTarget("hero")
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        detailScreen.animation = AlphaAnimation(1f, 0f).apply { duration = 300 }
        assertEquals(FLIGHT_LAND_RETURNED, host.flightRunEnded(finished = true))
        assertTrue(target.flightCovered)
        // Fabric deletes the target while its screen is still animating out.
        detailScreen.removeView(target)
        assertFalse(target.isAttachedToWindow)
        runFrames()
        assertFalse(host.flight.isUncoverPending)
        assertFalse(target.flightCovered)
    }

    @Test
    fun aTargetDroppedWhileItsExitingScreenDrawsItStaysCovered() {
        // Back starts the run home before the pop: the flight departs from
        // the detail target and covers it.
        val target = mountTarget("hero")
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        assertTrue(host.flight.isDeparting)
        detailScreen.animation = AlphaAnimation(1f, 0f).apply { duration = 300 }
        popTarget(target)
        // Fabric dropped it, but the exiting screen still draws it: revealed,
        // the detail hero would show beside its own flight home.
        assertTrue(target.isAttachedToWindow)
        assertTrue(target.flightCovered)
        assertEquals(FLIGHT_LAND_RETURNED, host.flightRunEnded(finished = true))
        runFrames()
        assertTrue(target.flightCovered)
        // It leaves the window with its screen: uncovered, out of the registry.
        finishPop(target)
        runFrames()
        assertFalse(target.flightCovered)
        assertFalse(SmoothClipFlightTargets.hasRegisteredTarget("hero"))
        assertFalse(host.flight.isUncoverPending)
        assertFalse(SmoothClipFlightTargets.isAirborne("hero"))
        assertEquals(0, asyncHandoffs)
    }

    @Test
    fun aRunHomeThatLiftsAfterThePopCoversTheExitingTarget() {
        // The detail hero is on screen. react-native-screens detached the
        // list under it, so the run home that Back starts waits for its host.
        val target = mountTarget("hero")
        root.removeView(listScreen)
        assertEquals(FLIGHT_LIFT_NONE, host.flightLift())
        // The pop's mount drops the target first, while the exiting screen
        // keeps drawing it...
        detailScreen.animation = AlphaAnimation(1f, 0f).apply { duration = 300 }
        popTarget(target)
        // ...then react-native-screens attaches the list again, and the
        // pending run starts and lifts the host.
        root.addView(listScreen, 0)
        listScreen.layout(0, 0, 300, 600)
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        // The detail hero is what the flight leaves: hidden, not shown beside it.
        assertTrue(host.flight.isDeparting)
        assertTrue(target.flightCovered)
        assertEquals(FLIGHT_LAND_RETURNED, host.flightRunEnded(finished = true))
        assertTrue(target.flightCovered)
        finishPop(target)
        runFrames()
        assertFalse(target.flightCovered)
        assertFalse(SmoothClipFlightTargets.hasRegisteredTarget("hero"))
        assertFalse(SmoothClipFlightTargets.isAirborne("hero"))
    }

    @Test
    fun aLandingFlightNeverHandsOffToADroppedTarget() {
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        val target = mountTarget("hero")
        // Popped mid-flight with no run home, by an exit this test does not
        // see as a transition (an Animator, say).
        popTarget(target)
        assertTrue(target.flightCovered)
        // Gone from React: the flight waits for it to leave, never reveals it.
        assertEquals(FLIGHT_LAND_HELD, host.flightRunEnded(finished = true))
        runFrames()
        assertTrue(host.flight.isHolding)
        assertTrue(target.flightCovered)
        // Then it lands as a lost target: a handoff with nothing to reveal.
        finishPop(target)
        runFrames()
        assertFalse(host.flight.isHolding)
        assertNull(carrier())
        assertSame(host, host.presentationContainer.parent)
        assertEquals(1, asyncHandoffs)
        assertFalse(target.flightCovered)
    }

    @Test
    fun hostLossEndsAPendingUncover() {
        val target = mountTarget("hero")
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        detailScreen.animation = AlphaAnimation(1f, 0f).apply { duration = 300 }
        assertEquals(FLIGHT_LAND_RETURNED, host.flightRunEnded(finished = true))
        assertTrue(target.flightCovered)
        listScreen.removeView(host)
        SmoothClipViewManager().onDropViewInstance(host)
        assertFalse(host.flight.isUncoverPending)
        assertFalse(target.flightCovered)
    }

    @Test
    fun aNewLiftTakesOverAPendingUncover() {
        val target = mountTarget("hero")
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        detailScreen.animation = AlphaAnimation(1f, 0f).apply { duration = 300 }
        assertEquals(FLIGHT_LAND_RETURNED, host.flightRunEnded(finished = true))
        assertTrue(host.flight.isUncoverPending)
        // The target is covered, so this lift lands on it.
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        assertFalse(host.flight.isUncoverPending)
        assertFalse(host.flight.isDeparting)
        detailScreen.clearAnimation()
        runFrames()
        assertTrue(target.flightCovered)
        assertEquals(FLIGHT_LAND_HANDOFF, host.flightRunEnded(finished = true))
        assertFalse(target.flightCovered)
    }

    @Test
    fun aCancelledRunNeverHandsOff() {
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        val target = mountTarget("hero")
        assertTrue(target.flightCovered)
        // Attached, ready and out of transition: a finished run would hand off.
        assertEquals(FLIGHT_LAND_RETURNED, host.flightRunEnded(finished = false))
        assertFalse(target.flightCovered)
        assertSame(host, host.presentationContainer.parent)
        assertNull(carrier())
        assertFalse(host.flight.isHolding)
        assertEquals(0, asyncHandoffs)
    }

    @Test
    fun aCancelledRunReturnsWithoutWaitingForItsTarget() {
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        val target = mountTarget("hero", ready = false)
        assertEquals(FLIGHT_LAND_RETURNED, host.flightRunEnded(finished = false))
        assertFalse(host.flight.isHolding)
        assertFalse(target.flightCovered)
        // A later `ready` does not hand anything off.
        SmoothClipFlightTargetManager().updateProperties(
            target,
            ReactStylesDiffMap(JavaOnlyMap.of("ready", true)),
        )
        assertEquals(0, asyncHandoffs)
    }

    @Test
    fun anInteractionHoldsTheLiftUntilTheNextRunEnds() {
        val manager = SmoothClipFlightTargetManager()
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        val target = mountTarget("hero", ready = false)
        assertEquals(FLIGHT_LAND_HELD, host.flightRunEnded(finished = true))
        val carrier = carrier()
        // beginInteraction lifts again: the content stays airborne, held by
        // the interaction rather than by the target.
        assertEquals(FLIGHT_LIFT_CONTINUED, host.flightLift())
        assertFalse(host.flight.isHolding)
        manager.updateProperties(
            target,
            ReactStylesDiffMap(JavaOnlyMap.of("ready", true)),
        )
        runFrames()
        assertSame(carrier, carrier())
        assertTrue(target.flightCovered)
        assertEquals(0, asyncHandoffs)
        // The run that ends the interaction lands it.
        assertEquals(FLIGHT_LIFT_CONTINUED, host.flightLift())
        assertEquals(FLIGHT_LAND_HANDOFF, host.flightRunEnded(finished = true))
        assertFalse(target.flightCovered)
        assertNull(carrier())
    }

    @Test
    fun aLandingHeldOnlyForReadyPostsNoFrameRetries() {
        // Finding 12. The `ready` prop update retries the landing, so a held
        // landing that waits only for it must not poll every vsync while,
        // say, a full-resolution image loads.
        val manager = SmoothClipFlightTargetManager()
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift())
        val target = mountTarget("hero", ready = false)
        runFrames()
        assertEquals(FLIGHT_LAND_HELD, host.flightRunEnded(finished = true))
        assertTrue(host.flight.isHolding)
        assertTrue(frames.isEmpty())

        // Ready while its screen still animates: only a frame retry sees that
        // transition end, so the hold polls until then.
        detailScreen.animation = AlphaAnimation(1f, 0f).apply { duration = 300 }
        manager.updateProperties(
            target,
            ReactStylesDiffMap(JavaOnlyMap.of("ready", true)),
        )
        assertTrue(host.flight.isHolding)
        assertEquals(1, frames.size)
        detailScreen.clearAnimation()
        runFrames()
        assertFalse(host.flight.isHolding)
        assertFalse(target.flightCovered)
        assertNull(carrier())
        assertEquals(1, asyncHandoffs)
        assertTrue(frames.isEmpty())
    }

    @Test
    fun anInteractionWhoseDepartedTargetLeavesLandsTheHostAtRest() {
        // Finding 2. The detail route drives an interaction on the card's way
        // back (it follows its own dismissal) and is popped before any run
        // starts. When its target leaves, nothing is left to start the run
        // that would end the interaction: the flight lands as one that lost
        // its target, and the registry puts the card back at rest.
        val target = mountTarget("hero")
        assertEquals(FLIGHT_LIFT_NEW, host.flightLift(interaction = true))
        assertTrue(host.flight.isDeparting)
        assertTrue(target.flightCovered)
        detailScreen.animation = AlphaAnimation(1f, 0f).apply { duration = 300 }
        popTarget(target)
        runFrames()
        // Dropped, but still drawn by its exiting screen: still held.
        assertNotNull(carrier())
        assertTrue(target.flightCovered)

        finishPop(target)
        runFrames()
        assertNull(carrier())
        assertSame(host, host.presentationContainer.parent)
        assertEquals(1, asyncHandoffs)
        assertFalse(SmoothClipFlightTargets.isAirborne("hero"))
        assertFalse(host.flight.isHolding)
    }

    @Test
    fun aTargetTakesTheViewStylePropsACodegenDelegateDrops() {
        // A rounded, clipped target (`borderRadius` + `overflow: 'hidden'`,
        // as a View takes them): the codegen delegate used to drop both, so
        // the landed content drew square corners on Android.
        val target = mountTarget("hero")
        val manager = SmoothClipFlightTargetManager()
        manager.updateProperties(
            target,
            ReactStylesDiffMap(
                JavaOnlyMap.of(
                    "borderRadius", 20.0,
                    "borderTopLeftRadius", 8.0,
                    "overflow", "hidden",
                    "ready", false,
                ),
            ),
        )
        assertEquals("hidden", target.overflow)
        assertEquals(
            LengthPercentage(20f, LengthPercentageType.POINT),
            BackgroundStyleApplicator.getBorderRadius(target, BorderRadiusProp.BORDER_RADIUS),
        )
        assertEquals(
            LengthPercentage(8f, LengthPercentageType.POINT),
            BackgroundStyleApplicator.getBorderRadius(
                target,
                BorderRadiusProp.BORDER_TOP_LEFT_RADIUS,
            ),
        )
        // The component's own props still reach it, through the codegen delegate.
        assertFalse(target.flightReady)
        // Its content draws inside the clip: the target, not the container, clips.
        assertEquals("visible", target.contentContainer.overflow)

        // A percent radius (the codegen delegate threw on it), and removed
        // props reset, as on a View.
        manager.updateProperties(
            target,
            ReactStylesDiffMap(
                JavaOnlyMap.of(
                    "borderRadius", "50%",
                    "borderTopLeftRadius", null,
                    "overflow", null,
                ),
            ),
        )
        assertEquals(
            LengthPercentage(50f, LengthPercentageType.PERCENT),
            BackgroundStyleApplicator.getBorderRadius(target, BorderRadiusProp.BORDER_RADIUS),
        )
        assertNull(
            BackgroundStyleApplicator.getBorderRadius(
                target,
                BorderRadiusProp.BORDER_TOP_LEFT_RADIUS,
            ),
        )
        assertEquals("visible", target.overflow)
    }
}
