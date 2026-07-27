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
    fun matchesTheSharedNormalizerVectorTable() {
        // Mirrored in ios/tests/SmoothClipSharedGeometryTests.mm so this
        // Kotlin legacy path and the shared C++ normalizer (used for driver
        // deliveries in SmoothClipRegistry.cpp) provably agree.
        val vectors = listOf(
            // x, y, w, h, r, hostW, hostH -> left, top, right, bottom, radius
            arrayOf(-20f, -10f, 70f, 50f, 99f, 300f, 200f, 0f, 0f, 50f, 40f, 20f),
            arrayOf(400f, 300f, 20f, 20f, 8f, 300f, 200f, 300f, 200f, 300f, 200f, 0f),
            arrayOf(50f, 50f, -10f, -20f, -4f, 300f, 200f, 50f, 50f, 50f, 50f, 0f),
            arrayOf(10f, 10f, 500f, 500f, 30f, 300f, 200f, 10f, 10f, 300f, 200f, 30f),
            arrayOf(0f, 0f, 100f, 40f, 99f, 300f, 200f, 0f, 0f, 100f, 40f, 20f),
            arrayOf(5f, 5f, 20f, 20f, 10f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            arrayOf(-50f, -50f, 20f, 20f, 5f, 300f, 200f, 0f, 0f, 0f, 0f, 0f),
        )
        for (vector in vectors) {
            val (accepted, result) = normalize(
                vector[0],
                vector[1],
                vector[2],
                vector[3],
                vector[4],
                vector[5],
                vector[6],
            )
            assertTrue(accepted)
            assertEquals(
                Geometry(vector[7], vector[8], vector[9], vector[10], vector[11]),
                result,
            )
        }
    }

    @Test
    fun rejectsEveryNonFiniteChannelAtomically() {
        val nan = Float.NaN
        val cases = listOf(
            arrayOf(nan, 0f, 10f, 10f, 1f, 100f, 100f),
            arrayOf(0f, nan, 10f, 10f, 1f, 100f, 100f),
            arrayOf(0f, 0f, nan, 10f, 1f, 100f, 100f),
            arrayOf(0f, 0f, 10f, nan, 1f, 100f, 100f),
            arrayOf(0f, 0f, 10f, 10f, nan, 100f, 100f),
            arrayOf(0f, 0f, 10f, 10f, 1f, nan, 100f),
            arrayOf(0f, 0f, 10f, 10f, 1f, 100f, nan),
            arrayOf(Float.POSITIVE_INFINITY, 0f, 10f, 10f, 1f, 100f, 100f),
        )
        for (case in cases) {
            val (accepted, result) = normalize(
                case[0],
                case[1],
                case[2],
                case[3],
                case[4],
                case[5],
                case[6],
            )
            assertFalse(accepted)
            assertEquals(null, result)
        }
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

    @Test
    fun outlineDedupeIgnoresSubPixelMotionWithinTheSameRoundedEdges() {
        assertFalse(
            outlineChanged(
                10.2f,
                20.1f,
                100.4f,
                80.49f,
                12f,
                10,
                20,
                100,
                80,
                12f,
            ),
        )
        assertFalse(
            outlineChanged(
                10.49f,
                20.49f,
                100.49f,
                80.2f,
                12f,
                10,
                20,
                100,
                80,
                12f,
            ),
        )
    }

    @Test
    fun outlineDedupeDetectsChangesCrossingARoundedEdge() {
        assertTrue(
            outlineChanged(
                10.6f,
                20.1f,
                100.4f,
                80.4f,
                12f,
                10,
                20,
                100,
                80,
                12f,
            ),
        )
        assertTrue(
            outlineChanged(
                10.2f,
                20.1f,
                100.4f,
                80.4f,
                12.5f,
                10,
                20,
                100,
                80,
                12f,
            ),
        )
    }
}
