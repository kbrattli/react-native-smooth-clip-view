package com.smoothclipview

import android.graphics.Path
import android.graphics.RectF
import android.view.MotionEvent
import android.view.View
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.uimanager.ThemedReactContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.Mockito.mock
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
// API 36 support in Robolectric 4.16 requires a Java 21 test worker. CI stays
// on Java 17, so execute this API-stable View behavior against its latest
// supported Java-17 sandbox while the library itself still compiles at 36.
@Config(sdk = [35])
class SmoothClipViewRobolectricTest {
    private lateinit var view: SmoothClipView
    private lateinit var actions: MutableList<Int>

    @Before
    fun setUp() {
        val application = RuntimeEnvironment.getApplication()
        val reactContext = mock(ReactApplicationContext::class.java)
        val themedContext = ThemedReactContext(reactContext, application, null, -1)
        view = SmoothClipView(themedContext)
        actions = mutableListOf()
        val child = View(themedContext).apply {
            isClickable = true
            setOnTouchListener { _, event ->
                actions += event.actionMasked
                true
            }
        }
        view.contentContainer.addView(child)
        view.layout(0, 0, 100, 100)
        child.layout(0, 0, 100, 100)
        setUniformPresentationPx(view, 0f, 0f, 100f, 100f, 0f, 0f, 0f)
    }

    @Test
    fun emptyGeometryUpdatesRealVisibilityAndAccessibility() {
        assertEquals(View.VISIBLE, view.visibility)
        assertFalse(
            view.importantForAccessibility ==
                View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS,
        )

        setUniformPresentationPx(view, 0f, 0f, 0f, 100f, 0f, 0f, 0f)

        assertEquals(View.INVISIBLE, view.visibility)
        assertEquals(
            View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS,
            view.importantForAccessibility,
        )
    }

    @Test
    fun collapseDuringAcceptedStreamDispatchesDownThenCancel() {
        assertTrue(view.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 50f, 50f)))

        setUniformPresentationPx(view, 0f, 0f, 0f, 100f, 0f, 0f, 0f)

        assertEquals(listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_CANCEL), actions)
    }

    @Test
    fun normalStreamRemainsDownMoveUp() {
        assertTrue(view.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 50f, 50f)))
        assertTrue(view.dispatchTouchEvent(event(MotionEvent.ACTION_MOVE, 55f, 50f)))
        assertTrue(view.dispatchTouchEvent(event(MotionEvent.ACTION_UP, 55f, 50f)))

        assertEquals(
            listOf(
                MotionEvent.ACTION_DOWN,
                MotionEvent.ACTION_MOVE,
                MotionEvent.ACTION_UP,
            ),
            actions,
        )
    }

    @Test
    fun v3ContentScaleUsesCenteredPivotAndKeepsTranslationIndependent() {
        view.setClipPresentationPx(
            0f,
            0f,
            100f,
            100f,
            12f,
            12f,
            12f,
            12f,
            CLIP_CURVE_CIRCULAR,
            7f,
            -9f,
            1.5f,
        )

        assertEquals(50f, view.contentContainer.pivotX)
        assertEquals(50f, view.contentContainer.pivotY)
        assertEquals(1.5f, view.contentContainer.scaleX)
        assertEquals(1.5f, view.contentContainer.scaleY)
        assertEquals(7f, view.contentContainer.translationX)
        assertEquals(-9f, view.contentContainer.translationY)
    }

    @Test
    fun v3UniformCircularGeometryUsesFloatOutlineWithoutResidual() {
        view.setClipPresentationPx(
            0.25f,
            0.75f,
            80.5f,
            70.25f,
            12.5f,
            12.5f,
            12.5f,
            12.5f,
            CLIP_CURVE_CIRCULAR,
            0f,
            0f,
            1f,
        )

        assertTrue(privateBoolean("outlineUsesFloatRoundRect"))
        assertEquals(0f, privateFloat("clipResidualX"))
        assertEquals(0f, privateFloat("clipResidualY"))

    }

    @Test
    fun continuousCurveUsesPathHitTestingInsteadOfCircularCorners() {
        view.setClipPresentationPx(
            0f,
            0f,
            100f,
            100f,
            20f,
            20f,
            20f,
            20f,
            CLIP_CURVE_CONTINUOUS,
            0f,
            0f,
            1f,
        )

        // This point is outside a radius-20 quarter circle but inside the
        // library's continuous cubic, whose controls meet at the corner.
        assertTrue(view.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 95f, 5f)))
    }

    @Test
    fun v3RejectsInvalidScaleWithoutMutatingThePreviousPresentation() {
        view.setClipPresentationPx(
            0f, 0f, 100f, 100f,
            0f, 0f, 0f, 0f,
            CLIP_CURVE_CIRCULAR,
            3f, 4f, 2f,
        )
        view.setClipPresentationPx(
            0f, 0f, 100f, 100f,
            0f, 0f, 0f, 0f,
            CLIP_CURVE_CIRCULAR,
            30f, 40f, 0f,
        )

        assertEquals(2f, view.contentContainer.scaleX)
        assertEquals(3f, view.contentContainer.translationX)
        assertEquals(4f, view.contentContainer.translationY)
    }

    @Test
    fun boxShadowTracksVisibleApertureAndEmptyLifecycleWithoutElevation() {
        assertNull(privateObject("boxShadowPath"))
        assertNull(privateObject("boxShadowPaint"))
        view.setClipPresentationPx(
            0f, 0f, 100f, 100f,
            18f, 18f, 18f, 18f,
            CLIP_CURVE_CIRCULAR,
            0f, 0f, 1f,
            true, 0f, 0f, 0f, 0f, 0f, 2f, 64f, 5f,
        )
        assertNull(privateObject("boxShadowPath"))
        assertNull(privateObject("boxShadowPaint"))
        view.setClipPresentationPx(
            0f, 0f, 100f, 100f,
            18f, 18f, 18f, 18f,
            CLIP_CURVE_CIRCULAR,
            0f, 0f, 1f,
            true, 0f, 0f, 0f, 0.25f, 0f, 2f, 64f, 5f,
        )
        assertEquals(0f, view.elevation)
        assertEquals(RectF(-5f, -3f, 105f, 107f), boxShadowBounds())

        view.setClipPresentationPx(
            0f, 0f, 0f, 100f,
            18f, 18f, 18f, 18f,
            CLIP_CURVE_CIRCULAR,
            0f, 0f, 1f,
            true, 0f, 0f, 0f, 0.25f, 0f, 2f, 64f, 5f,
        )
        assertTrue(privatePath("boxShadowPath").isEmpty)

        view.setClipPresentationPx(
            0f, 0f, 100f, 100f,
            18f, 18f, 18f, 18f,
            CLIP_CURVE_CIRCULAR,
            0f, 0f, 1f,
            true, 0f, 0f, 0f, 0.25f, 0f, 2f, 64f, 5f,
        )
        assertEquals(RectF(-5f, -3f, 105f, 107f), boxShadowBounds())
    }

    @Test
    fun boxShadowUsesDynamicPerCornerAndContinuousOutlinePaths() {
        view.setClipPresentationPx(
            0f, 0f, 100f, 100f,
            4f, 12f, 20f, 28f,
            CLIP_CURVE_CIRCULAR,
            0f, 0f, 1f,
            true, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 7f,
        )
        assertTrue(privateBoolean("outlineUsesPath"))
        assertEquals(RectF(-7f, -7f, 107f, 107f), boxShadowBounds())

        view.setClipPresentationPx(
            3f, 5f, 94f, 91f,
            22f, 22f, 22f, 22f,
            CLIP_CURVE_CONTINUOUS,
            0f, 0f, 1f,
            true, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 9f,
        )
        assertTrue(privateBoolean("outlineUsesPath"))
        assertEquals(RectF(-6f, -4f, 103f, 100f), boxShadowBounds())
    }

    @Test
    fun collapseWithoutAStreamDoesNotSynthesizeCancel() {
        setUniformPresentationPx(view, 0f, 0f, 0f, 100f, 0f, 0f, 0f)

        assertTrue(actions.isEmpty())
    }

    @Test
    fun reentrantCollapseFromTheCancelHandlerDispatchesExactlyOneCancel() {
        val application = RuntimeEnvironment.getApplication()
        val reactContext = mock(ReactApplicationContext::class.java)
        val themedContext = ThemedReactContext(reactContext, application, null, -1)
        val reentrantView = SmoothClipView(themedContext)
        val reentrantActions = mutableListOf<Int>()
        var collapsedFromHandler = false
        val child = View(themedContext).apply {
            isClickable = true
            setOnTouchListener { _, event ->
                reentrantActions += event.actionMasked
                if (event.actionMasked == MotionEvent.ACTION_CANCEL &&
                    !collapsedFromHandler
                ) {
                    // Untrusted child code re-entering geometry application
                    // synchronously from the synthesized cancel: the stream
                    // must already read as ended, or this nested collapse
                    // would synthesize a second cancel.
                    collapsedFromHandler = true
                    setUniformPresentationPx(
                        reentrantView, 0f, 0f, 0f, 100f, 0f, 0f, 0f,
                    )
                }
                true
            }
        }
        reentrantView.contentContainer.addView(child)
        reentrantView.layout(0, 0, 100, 100)
        child.layout(0, 0, 100, 100)
        setUniformPresentationPx(
            reentrantView, 0f, 0f, 100f, 100f, 0f, 0f, 0f,
        )

        assertTrue(
            reentrantView.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 50f, 50f)),
        )
        setUniformPresentationPx(
            reentrantView, 0f, 0f, 0f, 100f, 0f, 0f, 0f,
        )

        assertEquals(
            listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_CANCEL),
            reentrantActions,
        )
    }

    private fun event(action: Int, x: Float, y: Float): MotionEvent =
        MotionEvent.obtain(10L, 20L, action, x, y, 0)

    private fun setUniformPresentationPx(
        target: SmoothClipView,
        left: Float,
        top: Float,
        right: Float,
        bottom: Float,
        radius: Float,
        translateX: Float,
        translateY: Float,
    ) {
        target.setClipPresentationPx(
            left,
            top,
            right,
            bottom,
            radius,
            radius,
            radius,
            radius,
            CLIP_CURVE_CIRCULAR,
            translateX,
            translateY,
            1f,
        )
    }

    private fun privateBoolean(name: String): Boolean =
        SmoothClipView::class.java.getDeclaredField(name).let { field ->
            field.isAccessible = true
            field.getBoolean(view)
        }

    private fun privateFloat(name: String): Float =
        SmoothClipView::class.java.getDeclaredField(name).let { field ->
            field.isAccessible = true
            field.getFloat(view)
        }

    private fun privatePath(name: String): Path =
        SmoothClipView::class.java.getDeclaredField(name).let { field ->
            field.isAccessible = true
            field.get(view) as Path
        }

    private fun privateObject(name: String): Any? =
        SmoothClipView::class.java.getDeclaredField(name).let { field ->
            field.isAccessible = true
            field.get(view)
        }

    private fun boxShadowBounds(): RectF = RectF().also {
        privatePath("boxShadowPath").computeBounds(it, true)
    }
}
