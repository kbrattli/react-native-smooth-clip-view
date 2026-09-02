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

    private fun canonicalize(
        x: Float,
        y: Float,
        width: Float,
        height: Float,
        radius: Float,
    ): Pair<Boolean, Geometry?> {
        var result: Geometry? = null
        val accepted = canonicalizeClipGeometryPx(
            x,
            y,
            width,
            height,
            radius,
        ) { left, top, right, bottom, canonicalRadius ->
            result = Geometry(left, top, right, bottom, canonicalRadius)
        }
        return accepted to result
    }

    private data class GeometryValue(
        val left: Float,
        val top: Float,
        val right: Float,
        val bottom: Float,
        val topLeftRadius: Float,
        val topRightRadius: Float,
        val bottomRightRadius: Float,
        val bottomLeftRadius: Float,
        val curveCode: Int,
    )

    private fun canonicalizeValue(
        x: Float,
        y: Float,
        width: Float,
        height: Float,
        topLeftRadius: Float,
        topRightRadius: Float,
        bottomRightRadius: Float,
        bottomLeftRadius: Float,
        curveCode: Int = CLIP_CURVE_CIRCULAR,
    ): Pair<Boolean, GeometryValue?> {
        var result: GeometryValue? = null
        val accepted = canonicalizeClipGeometryPx(
            x,
            y,
            width,
            height,
            topLeftRadius,
            topRightRadius,
            bottomRightRadius,
            bottomLeftRadius,
            curveCode,
        ) { left, top, right, bottom, topLeft, topRight, bottomRight, bottomLeft, curve ->
            result = GeometryValue(
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
        return accepted to result
    }

    @Test
    fun rejectsArithmeticOverflow() {
        assertFalse(
            canonicalize(
                Float.MAX_VALUE,
                0f,
                Float.MAX_VALUE,
                20f,
                4f,
            ).first,
        )
        assertFalse(
            canonicalizeValue(
                0f,
                Float.MAX_VALUE,
                20f,
                Float.MAX_VALUE,
                4f,
                4f,
                4f,
                4f,
            ).first,
        )
    }

    @Test
    fun v3UsesOneCssOverlapFactorForAllCorners() {
        val (accepted, result) = canonicalizeValue(
            0f,
            0f,
            100f,
            80f,
            topLeftRadius = 80f,
            topRightRadius = 20f,
            bottomRightRadius = 20f,
            bottomLeftRadius = 80f,
            curveCode = CLIP_CURVE_CONTINUOUS,
        )

        assertTrue(accepted)
        assertEquals(
            GeometryValue(
                0f,
                0f,
                100f,
                80f,
                40f,
                10f,
                10f,
                40f,
                CLIP_CURVE_CONTINUOUS,
            ),
            result,
        )
    }

    @Test
    fun v3RejectsInvalidCurveAndNonFiniteCornerAtomically() {
        val (invalidCurveAccepted, invalidCurveResult) = canonicalizeValue(
            0f, 0f, 100f, 80f, 10f, 10f, 10f, 10f, curveCode = 2,
        )
        val (nanAccepted, nanResult) = canonicalizeValue(
            0f, 0f, 100f, 80f, Float.NaN, 10f, 10f, 10f,
        )

        assertFalse(invalidCurveAccepted)
        assertEquals(null, invalidCurveResult)
        assertFalse(nanAccepted)
        assertEquals(null, nanResult)
    }

    @Test
    fun preservesOffHostGeometryAndClampsRadiusAgainstRequestedRect() {
        val (accepted, result) = canonicalize(-20f, -10f, 70f, 50f, 99f)

        assertTrue(accepted)
        assertEquals(Geometry(-20f, -10f, 50f, 40f, 25f), result)
    }

    @Test
    fun preservesGeometryFullyOutsideTheHost() {
        val (accepted, result) = canonicalize(400f, 300f, 20f, 20f, 8f)

        assertTrue(accepted)
        assertEquals(Geometry(400f, 300f, 420f, 320f, 8f), result)
    }

    @Test
    fun clampsNegativeDimensionsAndRadius() {
        val (accepted, result) = canonicalize(50f, 50f, -10f, -20f, -4f)

        assertTrue(accepted)
        assertEquals(Geometry(50f, 50f, 50f, 50f, 0f), result)
    }

    @Test
    fun rejectsNonFiniteInputAtomically() {
        val (accepted, result) = canonicalize(0f, 0f, Float.NaN, 20f, 4f)

        assertFalse(accepted)
        assertEquals(null, result)
    }

    @Test
    fun matchesTheSharedNormalizerVectorTable() {
        // Mirrored in ios/tests/SmoothClipSharedGeometryTests.mm so this
        // Kotlin and the shared C++ canonicalizer (used for driver
        // deliveries in SmoothClipRegistry.cpp) provably agree.
        val vectors = listOf(
            // x, y, w, h, r -> left, top, right, bottom, radius
            arrayOf(-20f, -10f, 70f, 50f, 99f, -20f, -10f, 50f, 40f, 25f),
            arrayOf(400f, 300f, 20f, 20f, 8f, 400f, 300f, 420f, 320f, 8f),
            arrayOf(50f, 50f, -10f, -20f, -4f, 50f, 50f, 50f, 50f, 0f),
            arrayOf(10f, 10f, 500f, 500f, 30f, 10f, 10f, 510f, 510f, 30f),
            arrayOf(0f, 0f, 100f, 40f, 99f, 0f, 0f, 100f, 40f, 20f),
            arrayOf(5f, 5f, 20f, 20f, 10f, 5f, 5f, 25f, 25f, 10f),
            arrayOf(-50f, -50f, 20f, 20f, 5f, -50f, -50f, -30f, -30f, 5f),
        )
        for (vector in vectors) {
            val (accepted, result) = canonicalize(
                vector[0],
                vector[1],
                vector[2],
                vector[3],
                vector[4],
            )
            assertTrue(accepted)
            assertEquals(
                Geometry(vector[5], vector[6], vector[7], vector[8], vector[9]),
                result,
            )
        }
    }

    @Test
    fun rejectsEveryNonFiniteChannelAtomically() {
        val nan = Float.NaN
        val cases = listOf(
            arrayOf(nan, 0f, 10f, 10f, 1f),
            arrayOf(0f, nan, 10f, 10f, 1f),
            arrayOf(0f, 0f, nan, 10f, 1f),
            arrayOf(0f, 0f, 10f, nan, 1f),
            arrayOf(0f, 0f, 10f, 10f, nan),
            arrayOf(Float.POSITIVE_INFINITY, 0f, 10f, 10f, 1f),
        )
        for (case in cases) {
            val (accepted, result) = canonicalize(
                case[0],
                case[1],
                case[2],
                case[3],
                case[4],
            )
            assertFalse(accepted)
            assertEquals(null, result)
        }
    }

    @Test
    fun mapsEmptyAndVisiblePresentationWithoutLosingAccessibilityIntent() {
        assertEquals(View.INVISIBLE, renderVisibility(false))
        assertEquals(
            View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS,
            clipAccessibility(true, View.IMPORTANT_FOR_ACCESSIBILITY_YES),
        )

        assertEquals(View.VISIBLE, renderVisibility(true))
        assertEquals(
            View.IMPORTANT_FOR_ACCESSIBILITY_YES,
            clipAccessibility(false, View.IMPORTANT_FOR_ACCESSIBILITY_YES),
        )
    }

}
