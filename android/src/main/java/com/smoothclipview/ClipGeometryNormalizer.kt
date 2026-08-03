package com.smoothclipview

import android.view.View
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Normalizes clip geometry without allocating a result object. The callback is
 * inlined into the view's command path so per-frame updates stay allocation-free.
 */
internal inline fun normalizeClipGeometryPx(
    x: Float,
    y: Float,
    width: Float,
    height: Float,
    radius: Float,
    hostWidth: Float,
    hostHeight: Float,
    apply: (
        left: Float,
        top: Float,
        right: Float,
        bottom: Float,
        radius: Float,
    ) -> Unit,
): Boolean {
    if (!x.isFinite() || !y.isFinite() || !width.isFinite() ||
        !height.isFinite() || !radius.isFinite() ||
        !hostWidth.isFinite() || !hostHeight.isFinite()
    ) {
        return false
    }

    val boundedHostWidth = hostWidth.coerceAtLeast(0f)
    val boundedHostHeight = hostHeight.coerceAtLeast(0f)
    val requestedRight = x + width.coerceAtLeast(0f)
    val requestedBottom = y + height.coerceAtLeast(0f)
    val left = x.coerceIn(0f, boundedHostWidth)
    val top = y.coerceIn(0f, boundedHostHeight)
    val right = requestedRight.coerceIn(0f, boundedHostWidth)
    val bottom = requestedBottom.coerceIn(0f, boundedHostHeight)
    val visibleWidth = max(0f, right - left)
    val visibleHeight = max(0f, bottom - top)
    val normalizedRadius = min(
        radius.coerceAtLeast(0f),
        min(visibleWidth, visibleHeight) / 2f,
    )

    apply(left, top, right, bottom, normalizedRadius)
    return true
}

internal fun clipVisibility(isEmpty: Boolean): Int =
    if (isEmpty) View.INVISIBLE else View.VISIBLE

/** Rounded integer origin of an outline edge. */
internal fun outlineOrigin(value: Float): Int = value.roundToInt()

/**
 * Rounded far edge, derived from the rounded origin plus the rounded extent.
 *
 * `Outline.setRoundRect` takes an int rect, and rounding the two edges
 * independently makes `round(far) - round(origin)` alternate between the floor
 * and the ceil of a *constant* extent as the origin's fraction sweeps: a pure
 * translation breathes the emitted size by 1 px, frame after frame, while the
 * content inside translates in floats. That oscillation is what reads as
 * shimmer on the slow tail of an animation, where the per-frame delta drops
 * below a pixel and the rounding becomes the motion.
 *
 * An int rect cannot hold origin, far edge and extent within half a pixel at
 * once (extent = far - origin, so bounding both edges at 0.5 bounds the extent
 * at 1.0); the only choice is which error oscillates. Deriving the far edge
 * makes the emitted extent a pure function of the true extent — stable, error
 * <= 0.5 px — and moves the slack onto the far edge, <= 1.0 px and static. A
 * static bias does not read as jank; an alternating one does.
 *
 * Two consequences, both benign:
 * - The far edge can overshoot the host bound by up to 1 px instead of 0.5. The
 *   view's own bounds already clip, so an over-large outline just means that
 *   edge is not clipped that frame — which independent rounding already
 *   produced whenever `round(far)` rounded up.
 * - A sub-pixel extent (0 < extent < 0.5) rounds to a degenerate rect, which
 *   `Outline.setRoundRect` collapses to `setEmpty()`. Independent rounding hit
 *   that state on some frames and a 1 px rect on others, i.e. it flickered;
 *   deriving the far edge makes it consistent. The emitted integer rect also
 *   governs visibility, accessibility and hit testing, so a view never remains
 *   logically visible while its outline clips every pixel.
 */
internal fun outlineFarEdge(origin: Float, far: Float): Int =
    outlineOrigin(origin) + (far - origin).roundToInt()

/** Exactly mirrors the non-empty requirement of Outline.setRoundRect(Int...). */
internal fun outlineRectIsEmpty(
    left: Int,
    top: Int,
    right: Int,
    bottom: Int,
): Boolean = right <= left || bottom <= top

/**
 * Outline dedupe on the rounded integer physical-pixel edges actually emitted
 * to the outline provider. Takes the already-derived edges rather than raw
 * floats so the caller rounds once per frame and the predicate can never drift
 * from what the provider emits; the radius stays a float comparison because it
 * is emitted to the outline as a float.
 *
 * Sub-pixel motion that rounds to the cached integers must NOT invalidate the
 * outline — it is carried on the view's translation instead (see
 * SmoothClipView.applyClipPlacement), which is both cheaper and smoother than
 * restaging an identical rect.
 */
internal fun outlineChanged(
    left: Int,
    top: Int,
    right: Int,
    bottom: Int,
    radius: Float,
    cachedLeft: Int,
    cachedTop: Int,
    cachedRight: Int,
    cachedBottom: Int,
    cachedRadius: Float,
): Boolean =
    left != cachedLeft ||
        top != cachedTop ||
        right != cachedRight ||
        bottom != cachedBottom ||
        radius != cachedRadius

internal fun clipAccessibility(
    isEmpty: Boolean,
    requestedAccessibility: Int,
): Int =
    if (isEmpty) {
        View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
    } else {
        requestedAccessibility
    }

internal fun containsRoundedPointPx(
    x: Float,
    y: Float,
    left: Float,
    top: Float,
    right: Float,
    bottom: Float,
    radius: Float,
    isEmpty: Boolean,
): Boolean {
    if (isEmpty || x < left || x > right || y < top || y > bottom) {
        return false
    }

    if (radius <= 0f) return true

    val innerLeft = left + radius
    val innerRight = right - radius
    val innerTop = top + radius
    val innerBottom = bottom - radius
    if (x in innerLeft..innerRight || y in innerTop..innerBottom) return true

    val centerX = if (x < innerLeft) innerLeft else innerRight
    val centerY = if (y < innerTop) innerTop else innerBottom
    val dx = x - centerX
    val dy = y - centerY
    return dx * dx + dy * dy <= radius * radius
}
