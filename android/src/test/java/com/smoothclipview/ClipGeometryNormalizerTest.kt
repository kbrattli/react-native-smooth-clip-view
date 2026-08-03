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

    /** Mirrors what SmoothClipView.applyNormalizedClipPx derives per frame. */
    private fun outlineChangedFor(
        left: Float,
        top: Float,
        right: Float,
        bottom: Float,
        radius: Float,
        cachedLeft: Int,
        cachedTop: Int,
        cachedRight: Int,
        cachedBottom: Int,
        cachedRadius: Float,
    ): Boolean =
        outlineChanged(
            outlineOrigin(left),
            outlineOrigin(top),
            outlineFarEdge(left, right),
            outlineFarEdge(top, bottom),
            radius,
            cachedLeft,
            cachedTop,
            cachedRight,
            cachedBottom,
            cachedRadius,
        )

    @Test
    fun outlineDedupeIgnoresSubPixelMotionWithinTheSameRoundedEdges() {
        assertFalse(
            outlineChangedFor(
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
            outlineChangedFor(
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
    fun subPixelMotionSurvivesAsAResidualEvenWhenTheOutlineDedupes() {
        // The frames the dedupe skips are exactly the ones that used to freeze
        // the clip: the rounded rect is unchanged, so nothing was restaged and
        // the edge held while the content kept sliding. The residual the view
        // carries on its own translation is what still moves on those frames.
        val extent = 90.4f
        var previousResidual = Float.NaN
        for (origin in listOf(10.05f, 10.15f, 10.25f, 10.35f)) {
            val left = outlineOrigin(origin)
            assertEquals(10, left)
            val residual = origin - left
            assertTrue(
                "sub-pixel motion must not be lost when the outline dedupes",
                residual != previousResidual,
            )
            previousResidual = residual
            // ...and the size the outline emits stays put through all of it.
            assertEquals(90, outlineFarEdge(origin, origin + extent) - left)
        }
    }

    @Test
    fun emitsAStableOutlineSizeWhileTranslatingANonIntegerExtent() {
        // The artifact this guards: rounding both edges independently makes
        // round(right) - round(left) alternate between floor and ceil of a
        // constant extent as the origin's fraction sweeps, so a pure
        // translation breathes the emitted size by 1 px every frame. Under the
        // old scheme this table produced widths 91, 91, 90, 90, 90, 91; the
        // extent has to be non-integer for the two schemes to disagree at all.
        val extent = 90.4f
        for (origin in listOf(10.2f, 10.4f, 10.6f, 10.8f, 11.0f, 11.2f)) {
            val left = outlineOrigin(origin)
            val right = outlineFarEdge(origin, origin + extent)
            assertEquals(
                "emitted width changed while translating at constant extent",
                90,
                right - left,
            )
        }
    }

    @Test
    fun subHalfPixelExtentsAreSemanticallyEmptyLikeTheirOutline() {
        val left = outlineOrigin(10.2f)
        val top = outlineOrigin(20.2f)
        val right = outlineFarEdge(10.2f, 10.59f)
        val bottom = outlineFarEdge(20.2f, 20.59f)

        assertEquals(left, right)
        assertEquals(top, bottom)
        assertTrue(outlineRectIsEmpty(left, top, right, bottom))
        assertEquals(View.INVISIBLE, clipVisibility(true))
    }

    @Test
    fun halfPixelExtentsCrossTheVisibilityThreshold() {
        val left = outlineOrigin(10.2f)
        val top = outlineOrigin(20.2f)
        val right = outlineFarEdge(10.2f, 10.7f)
        val bottom = outlineFarEdge(20.2f, 20.7f)

        assertEquals(1, right - left)
        assertEquals(1, bottom - top)
        assertFalse(outlineRectIsEmpty(left, top, right, bottom))
        assertEquals(View.VISIBLE, clipVisibility(false))
    }

    @Test
    fun emptinessCannotFlipWhileTheEmittedEdgesStayUnchanged() {
        val samples = listOf(
            floatArrayOf(10.05f, 20.05f, 10.44f, 20.44f),
            floatArrayOf(10.2f, 20.2f, 10.59f, 20.59f),
            floatArrayOf(10.49f, 20.49f, 10.88f, 20.88f),
            floatArrayOf(10.2f, 20.2f, 10.7f, 20.7f),
            floatArrayOf(10.35f, 20.35f, 10.85f, 20.85f),
        )
        val emptinessByEdges = mutableMapOf<List<Int>, Boolean>()

        for (sample in samples) {
            val edges = listOf(
                outlineOrigin(sample[0]),
                outlineOrigin(sample[1]),
                outlineFarEdge(sample[0], sample[2]),
                outlineFarEdge(sample[1], sample[3]),
            )
            val empty = outlineRectIsEmpty(
                edges[0],
                edges[1],
                edges[2],
                edges[3],
            )
            val previous = emptinessByEdges.putIfAbsent(edges, empty)
            if (previous != null) assertEquals(previous, empty)
        }
    }

    @Test
    fun outlineDedupeStillFiresWhenTheOriginCrossesARoundedEdge() {
        // Size stability must not make the dedupe blind to real motion: at a
        // constant extent the origin still steps, and that step has to
        // invalidate the outline.
        assertTrue(
            outlineChangedFor(
                10.6f,
                20.6f,
                101.0f,
                80.6f,
                12f,
                outlineOrigin(10.4f),
                outlineOrigin(20.4f),
                outlineFarEdge(10.4f, 100.8f),
                outlineFarEdge(20.4f, 80.4f),
                12f,
            ),
        )
    }

    @Test
    fun outlineDedupeDetectsChangesCrossingARoundedEdge() {
        assertTrue(
            outlineChangedFor(
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
            outlineChangedFor(
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
