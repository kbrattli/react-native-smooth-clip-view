package com.smoothclipview

import android.view.View
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipGeometryNormalizerTest {
    private data class Geometry(
        val left: Float,
        val top: Float,
        val right: Float,
        val bottom: Float,
        val radius: Float,
    )

    private fun normalize(
        x: Float,
        y: Float,
        width: Float,
        height: Float,
        radius: Float,
        hostWidth: Float = 300f,
        hostHeight: Float = 200f,
    ): Pair<Boolean, Geometry?> {
        var result: Geometry? = null
        val accepted = normalizeClipGeometryPx(
            x,
            y,
            width,
            height,
            radius,
            hostWidth,
            hostHeight,
        ) { left, top, right, bottom, normalizedRadius ->
            result = Geometry(left, top, right, bottom, normalizedRadius)
        }
        return accepted to result
    }

    @Test
    fun intersectsGeometryAndClampsRadius() {
        val (accepted, result) = normalize(-20f, -10f, 70f, 50f, 99f)

        assertTrue(accepted)
        assertEquals(Geometry(0f, 0f, 50f, 40f, 20f), result)
    }

    @Test
    fun producesEmptyGeometryOutsideTheHost() {
        val (accepted, result) = normalize(400f, 300f, 20f, 20f, 8f)

        assertTrue(accepted)
        assertEquals(Geometry(300f, 200f, 300f, 200f, 0f), result)
    }

    @Test
    fun clampsNegativeDimensionsAndRadius() {
        val (accepted, result) = normalize(50f, 50f, -10f, -20f, -4f)

        assertTrue(accepted)
        assertEquals(Geometry(50f, 50f, 50f, 50f, 0f), result)
    }

    @Test
    fun rejectsNonFiniteInputAtomically() {
        val (accepted, result) = normalize(0f, 0f, Float.NaN, 20f, 4f)

        assertFalse(accepted)
        assertEquals(null, result)
    }

    @Test
    fun mapsEmptyAndVisiblePresentationWithoutLosingAccessibilityIntent() {
        assertEquals(View.INVISIBLE, clipVisibility(true))
        assertEquals(
            View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS,
            clipAccessibility(true, View.IMPORTANT_FOR_ACCESSIBILITY_YES),
        )

        assertEquals(View.VISIBLE, clipVisibility(false))
        assertEquals(
            View.IMPORTANT_FOR_ACCESSIBILITY_YES,
            clipAccessibility(false, View.IMPORTANT_FOR_ACCESSIBILITY_YES),
        )
    }

    @Test
    fun rejectsRoundedCornersButAcceptsTheCenterAndSquareEdges() {
        assertFalse(
            containsRoundedPointPx(
                1f,
                1f,
                0f,
                0f,
                100f,
                40f,
                20f,
                false,
            ),
        )
        assertTrue(
            containsRoundedPointPx(
                50f,
                20f,
                0f,
                0f,
                100f,
                40f,
                20f,
                false,
            ),
        )
        assertTrue(
            containsRoundedPointPx(
                1f,
                1f,
                0f,
                0f,
                100f,
                40f,
                0f,
                false,
            ),
        )
        assertFalse(
            containsRoundedPointPx(
                50f,
                20f,
                0f,
                0f,
                100f,
                40f,
                0f,
                true,
            ),
        )
    }
}
