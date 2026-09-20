package com.smoothclipview

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Outline
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
import org.robolectric.annotation.GraphicsMode

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
    @Config(sdk = [26, 32])
    @GraphicsMode(GraphicsMode.Mode.NATIVE)
    fun renderedRotationAndGroupOpacityPreserveClippingAndOverlap() {
        view.contentContainer.getChildAt(0).setBackgroundColor(Color.RED)
        val overlap = View(view.context).apply { setBackgroundColor(Color.BLUE) }
        view.contentContainer.addView(overlap)
        overlap.layout(40, 0, 100, 100)
        view.setClipPresentationPx(20f, 40f, 80f, 60f, 0f, 0f, 0f, 0f,
            CLIP_CURVE_CIRCULAR, 0f, 0f, 1f, rotation = Math.PI / 2, opacity = 0.5f)
        val bitmap = Bitmap.createBitmap(100, 100, Bitmap.Config.ARGB_8888)
        view.draw(Canvas(bitmap))
        assertEquals(0, Color.alpha(bitmap.getPixel(25, 50)))
        assertEquals(128f, Color.alpha(bitmap.getPixel(50, 25)).toFloat(), 1f)
        assertEquals(128f, Color.alpha(bitmap.getPixel(50, 60)).toFloat(), 1f)
        assertEquals(255, Color.blue(bitmap.getPixel(50, 60)))
    }

    @Test
    @Config(sdk = [28, 35])
    fun rotatedOffHostContentStillReceivesTouches() {
        view.setClipPresentationPx(-30f, 0f, -10f, 100f, 0f, 0f, 0f, 0f,
            CLIP_CURVE_CIRCULAR, -30f, 0f, 1f, rotation = Math.PI / 2)
        assertTrue(view.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 10f, 50f)))
        assertTrue(view.dispatchTouchEvent(event(MotionEvent.ACTION_UP, 10f, 50f)))
        assertEquals(listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP), actions)
    }

    @Test
    @Config(sdk = [28, 35])
    fun wholeObjectRotationAndOpacityKeepHostAndTouchCoordinatesCorrect() {
        view.setClipPresentationPx(20f, 40f, 80f, 60f, 0f, 0f, 0f, 0f,
            CLIP_CURVE_CIRCULAR, 0f, 0f, 1f, rotation = Math.PI / 2, opacity = 0.5f)
        assertEquals(90f, view.presentationContainer.rotation, 0.001f)
        assertEquals(50f, view.presentationContainer.pivotX, 0.001f)
        assertEquals(50f, view.presentationContainer.pivotY, 0.001f)
        assertEquals(0.5f, view.presentationContainer.alpha, 0.001f)
        assertTrue(view.presentationContainer.hasOverlappingRendering())
        assertFalse(view.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 25f, 50f)))
        assertTrue(view.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 50f, 25f)))
        assertTrue(view.dispatchTouchEvent(event(MotionEvent.ACTION_UP, 50f, 25f)))
        assertEquals(listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP), actions)
        view.setClipPresentationPx(20f, 40f, 80f, 60f, 0f, 0f, 0f, 0f,
            CLIP_CURVE_CIRCULAR, 0f, 0f, 1f, rotation = Math.PI / 2, opacity = 0f)
        assertFalse(view.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 50f, 50f)))
        assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS, view.importantForAccessibility)
    }

    @Test
    @Config(sdk = [28, 35])
    fun offHostApertureCanRotateBackIntoTheViewport() {
        view.setClipPresentationPx(-30f, 0f, -10f, 100f, 0f, 0f, 0f, 0f,
            CLIP_CURVE_CIRCULAR, 0f, 0f, 1f)
        assertEquals(View.INVISIBLE, view.visibility)
        view.setClipPresentationPx(-30f, 0f, -10f, 100f, 0f, 0f, 0f, 0f,
            CLIP_CURVE_CIRCULAR, 0f, 0f, 1f, rotation = Math.PI / 2)
        assertEquals(View.VISIBLE, view.visibility)
        assertFalse(view.importantForAccessibility == View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS)
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
    fun offHostApertureKeepsShadowRenderingButHidesAccessibilityAndTouch() {
        view.setClipPresentationPx(
            -30f, 20f, -10f, 40f,
            6f, 6f, 6f, 6f,
            CLIP_CURVE_CIRCULAR,
            0f, 0f, 1f,
            true, 0f, 0f, 0f, 0.25f, 20f, 0f, 0f, 0f,
        )

        assertEquals(View.VISIBLE, view.visibility)
        assertEquals(
            View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS,
            view.importantForAccessibility,
        )
        assertEquals(RectF(-10f, 20f, 10f, 40f), boxShadowBounds())
        assertFalse(view.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 0f, 30f)))
    }

    @Test
    fun fullyOffHostApertureWithoutAnOverlappingShadowIsCulled() {
        setUniformPresentationPx(view, -30f, 20f, -10f, 40f, 6f, 0f, 0f)

        assertEquals(View.INVISIBLE, view.visibility)
        assertEquals(
            View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS,
            view.importantForAccessibility,
        )
    }

    @Test
    fun partiallyOffHostApertureRemainsAccessibleAndUsesRawGeometry() {
        setUniformPresentationPx(view, -20f, 10f, 30f, 60f, 8f, 0f, 0f)

        assertFalse(
            view.importantForAccessibility ==
                View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS,
        )
        assertTrue(view.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 10f, 30f)))
    }

    @Test
    fun acceptedStreamSurvivesApertureLeavingHostUntilUp() {
        assertTrue(view.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 50f, 50f)))

        setUniformPresentationPx(view, -100f, 0f, -50f, 100f, 0f, 0f, 0f)
        assertTrue(view.dispatchTouchEvent(event(MotionEvent.ACTION_MOVE, 55f, 50f)))
        setUniformPresentationPx(view, 0f, 0f, 0f, 100f, 0f, 0f, 0f)
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
    fun uniformCircularGeometryUsesTheRawFloatPath() {
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

        assertEquals(RectF(0.25f, 0.75f, 80.5f, 70.25f), clipBounds())
    }

    @Test
    fun continuousCornerKeepsTheCircularApex() {
        setContinuousPresentationPx(100f, 20f)

        // The apex sits on the radius-20 circle, at (94.14, 5.86). A curve
        // pulled towards the corner point would still contain (95, 5).
        assertFalse(view.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 95f, 5f)))
        assertTrue(view.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 93.5f, 6.5f)))
    }

    @Test
    fun continuousCornerLeavesTheEdgeBeforeACircularOne() {
        setContinuousPresentationPx(1000f, 200f)

        // The shoulder starts at 1.6 * radius = 320 from the corner. Where a
        // circular corner would only begin (x = 800) it is already ~2 px in.
        assertTrue(view.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 670f, 0.5f)))
        assertFalse(view.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 800f, 1f)))
        assertTrue(view.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 800f, 3f)))
    }

    @Test
    fun continuousCornerWithoutShoulderRoomIsCircular() {
        setContinuousPresentationPx(100f, 50f)

        // No edge is left for a shoulder, so smoothing falls to zero: a circle
        // of radius 50 about (50, 50) passes between these two points.
        assertFalse(view.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 14f, 14f)))
        assertTrue(view.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 16f, 16f)))
    }

    @Test
    fun continuousCornersShareAnEdgeWithoutOverlapping() {
        view.setClipPresentationPx(
            0f, 0f, 100f, 100f,
            60f, 40f, 0f, 0f,
            CLIP_CURVE_CONTINUOUS,
            0f, 0f, 1f,
        )

        // 1.6 * (60 + 40) exceeds the top edge, so both shoulders are clamped
        // to their share of it. The square bottom corners stay plain vertices.
        assertEquals(RectF(0f, 0f, 100f, 100f), clipBounds())
        assertTrue(view.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 60f, 0.5f)))
        assertFalse(view.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 2f, 2f)))
        assertTrue(view.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 99f, 99f)))
        assertTrue(view.dispatchTouchEvent(event(MotionEvent.ACTION_DOWN, 1f, 99f)))
    }

    @Test
    @Config(sdk = [33, 35])
    fun roundedOutlineClipsOnSupportedAndroidVersions() {
        view.setClipPresentationPx(
            0.25f,
            0.75f,
            80.5f,
            70.25f,
            4f,
            12f,
            20f,
            24f,
            CLIP_CURVE_CONTINUOUS,
            0f,
            0f,
            1f,
        )

        val outline = Outline()
        val clipContainer = privateObject("clipContainer") as View
        clipContainer.outlineProvider.getOutline(clipContainer, outline)

        assertTrue(clipContainer.clipToOutline)
        assertFalse(outline.isEmpty)
        assertTrue(outline.canClip())
    }

    @Test
    @Config(sdk = [26, 32])
    @GraphicsMode(GraphicsMode.Mode.NATIVE)
    fun canvasPathClipsRenderedContentBeforePathOutlinesAreSupported() {
        view.contentContainer.getChildAt(0).setBackgroundColor(Color.RED)
        setUniformPresentationPx(view, 20f, 20f, 80f, 80f, 16f, 0f, 0f)

        val clipContainer = privateObject("clipContainer") as View
        assertFalse(clipContainer.clipToOutline)

        val bitmap = Bitmap.createBitmap(100, 100, Bitmap.Config.ARGB_8888)
        view.draw(Canvas(bitmap))

        assertEquals(Color.TRANSPARENT, bitmap.getPixel(10, 50))
        assertEquals(Color.RED, bitmap.getPixel(50, 50))
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
        assertEquals(RectF(0f, 0f, 100f, 100f), clipBounds())
        assertEquals(RectF(-7f, -7f, 107f, 107f), boxShadowBounds())

        view.setClipPresentationPx(
            3f, 5f, 94f, 91f,
            22f, 22f, 22f, 22f,
            CLIP_CURVE_CONTINUOUS,
            0f, 0f, 1f,
            true, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 9f,
        )
        assertEquals(RectF(3f, 5f, 94f, 91f), clipBounds())
        assertEquals(RectF(-6f, -4f, 103f, 100f), boxShadowBounds())
    }

    private fun event(action: Int, x: Float, y: Float): MotionEvent =
        MotionEvent.obtain(10L, 20L, action, x, y, 0)

    private fun setContinuousPresentationPx(size: Float, radius: Float) {
        view.layout(0, 0, size.toInt(), size.toInt())
        view.contentContainer.getChildAt(0).layout(0, 0, size.toInt(), size.toInt())
        view.setClipPresentationPx(
            0f, 0f, size, size,
            radius, radius, radius, radius,
            CLIP_CURVE_CONTINUOUS,
            0f, 0f, 1f,
        )
    }

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

    private fun clipBounds(): RectF = RectF().also {
        privatePath("clipPath").computeBounds(it, true)
    }
}
