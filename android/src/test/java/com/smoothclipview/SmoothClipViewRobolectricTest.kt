package com.smoothclipview

import android.view.MotionEvent
import android.view.View
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.uimanager.ThemedReactContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
        view.setClipPresentationPx(0f, 0f, 100f, 100f, 0f, 0f, 0f)
    }

    @Test
    fun subHalfPixelGeometryUpdatesRealVisibilityAndAccessibility() {
        assertEquals(View.VISIBLE, view.visibility)
        assertFalse(
            view.importantForAccessibility ==
                View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS,
        )

        view.setClipPresentationPx(0f, 0f, 0.49f, 100f, 0f, 0f, 0f)

        assertEquals(View.INVISIBLE, view.visibility)
        assertEquals(
            View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS,
            view.importantForAccessibility,
        )
    }

    @Test
    fun collapseDuringAcceptedStreamDispatchesDownThenCancel() {
        assertTrue(view.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 50f, 50f)))

        view.setClipPresentationPx(0f, 0f, 0.49f, 100f, 0f, 0f, 0f)

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
    fun collapseWithoutAStreamDoesNotSynthesizeCancel() {
        view.setClipPresentationPx(0f, 0f, 0.49f, 100f, 0f, 0f, 0f)

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
                    reentrantView.setClipPresentationPx(
                        0f, 0f, 0.2f, 100f, 0f, 0f, 0f,
                    )
                }
                true
            }
        }
        reentrantView.contentContainer.addView(child)
        reentrantView.layout(0, 0, 100, 100)
        child.layout(0, 0, 100, 100)
        reentrantView.setClipPresentationPx(0f, 0f, 100f, 100f, 0f, 0f, 0f)

        assertTrue(
            reentrantView.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 50f, 50f)),
        )
        reentrantView.setClipPresentationPx(0f, 0f, 0.49f, 100f, 0f, 0f, 0f)

        assertEquals(
            listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_CANCEL),
            reentrantActions,
        )
    }

    private fun event(action: Int, x: Float, y: Float): MotionEvent =
        MotionEvent.obtain(10L, 20L, action, x, y, 0)
}
