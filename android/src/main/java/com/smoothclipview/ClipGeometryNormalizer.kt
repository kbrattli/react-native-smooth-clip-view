package com.smoothclipview

import android.graphics.Path
import android.view.View
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

internal const val CLIP_CURVE_CIRCULAR = 0
internal const val CLIP_CURVE_CONTINUOUS = 1

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

/**
 * V2 normalization with independent radii. Radii use the CSS overlap rule:
 * one shared factor keeps all four corners proportional when any opposing pair
 * exceeds the visible width or height. This mirrors SmoothClipNormalizeV2 in
 * the shared C++ delivery path.
 */
internal inline fun normalizeClipGeometryV2Px(
    x: Float,
    y: Float,
    width: Float,
    height: Float,
    topLeftRadius: Float,
    topRightRadius: Float,
    bottomRightRadius: Float,
    bottomLeftRadius: Float,
    curveCode: Int,
    hostWidth: Float,
    hostHeight: Float,
    apply: (
        left: Float,
        top: Float,
        right: Float,
        bottom: Float,
        normalizedTopLeftRadius: Float,
        normalizedTopRightRadius: Float,
        normalizedBottomRightRadius: Float,
        normalizedBottomLeftRadius: Float,
        normalizedCurveCode: Int,
    ) -> Unit,
): Boolean {
    if (!x.isFinite() || !y.isFinite() || !width.isFinite() ||
        !height.isFinite() || !topLeftRadius.isFinite() ||
        !topRightRadius.isFinite() || !bottomRightRadius.isFinite() ||
        !bottomLeftRadius.isFinite() || !hostWidth.isFinite() ||
        !hostHeight.isFinite() ||
        (curveCode != CLIP_CURVE_CIRCULAR && curveCode != CLIP_CURVE_CONTINUOUS)
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
    val topLeft = topLeftRadius.coerceAtLeast(0f)
    val topRight = topRightRadius.coerceAtLeast(0f)
    val bottomRight = bottomRightRadius.coerceAtLeast(0f)
    val bottomLeft = bottomLeftRadius.coerceAtLeast(0f)

    var radiusScale = 1f
    val topWidth = topLeft + topRight
    val bottomWidth = bottomLeft + bottomRight
    val leftHeight = topLeft + bottomLeft
    val rightHeight = topRight + bottomRight
    if (topWidth > 0f) radiusScale = min(radiusScale, visibleWidth / topWidth)
    if (bottomWidth > 0f) radiusScale = min(radiusScale, visibleWidth / bottomWidth)
    if (leftHeight > 0f) radiusScale = min(radiusScale, visibleHeight / leftHeight)
    if (rightHeight > 0f) radiusScale = min(radiusScale, visibleHeight / rightHeight)
    radiusScale = radiusScale.coerceIn(0f, 1f)

    apply(
        left,
        top,
        right,
        bottom,
        topLeft * radiusScale,
        topRight * radiusScale,
        bottomRight * radiusScale,
        bottomLeft * radiusScale,
        curveCode,
    )
    return true
}

/**
 * Emits one fixed-topology rounded rectangle for both V2 curve families.
 * Circular uses the standard quarter-circle cubic coefficient; continuous
 * keeps both control points at the rectangle corner (coefficient 1), yielding
 * zero endpoint curvature and a visibly smoother shoulder. "Continuous" is a
 * library-defined cross-platform curve, not a claim of pixel identity with
 * Apple's private continuous-corner implementation.
 */
internal fun appendRoundedRectPath(
    path: Path,
    left: Float,
    top: Float,
    right: Float,
    bottom: Float,
    topLeftRadius: Float,
    topRightRadius: Float,
    bottomRightRadius: Float,
    bottomLeftRadius: Float,
    curveCode: Int,
) {
    val coefficient = if (curveCode == CLIP_CURVE_CONTINUOUS) {
        1f
    } else {
        0.5522848f
    }

    path.moveTo(left + topLeftRadius, top)
    path.lineTo(right - topRightRadius, top)
    path.cubicTo(
        right - topRightRadius + coefficient * topRightRadius,
        top,
        right,
        top + topRightRadius - coefficient * topRightRadius,
        right,
        top + topRightRadius,
    )
    path.lineTo(right, bottom - bottomRightRadius)
    path.cubicTo(
        right,
        bottom - bottomRightRadius + coefficient * bottomRightRadius,
        right - bottomRightRadius + coefficient * bottomRightRadius,
        bottom,
        right - bottomRightRadius,
        bottom,
    )
    path.lineTo(left + bottomLeftRadius, bottom)
    path.cubicTo(
        left + bottomLeftRadius - coefficient * bottomLeftRadius,
        bottom,
        left,
        bottom - bottomLeftRadius + coefficient * bottomLeftRadius,
        left,
        bottom - bottomLeftRadius,
    )
    path.lineTo(left, top + topLeftRadius)
    path.cubicTo(
        left,
        top + topLeftRadius - coefficient * topLeftRadius,
        left + topLeftRadius - coefficient * topLeftRadius,
        top,
        left + topLeftRadius,
        top,
    )
    path.close()
}

/**
 * Hit-tests the actual rendered path. Path has no float `contains` API, so we
 * flatten that same instance to sub-pixel line segments for ACTION_DOWN. This
 * is deliberately off the render/animation hot path and avoids maintaining a
 * second analytical curve that can drift from clipping geometry.
 */
internal fun containsPathPoint(path: Path, x: Float, y: Float): Boolean {
    if (!x.isFinite() || !y.isFinite() || path.isEmpty) return false
    val points = path.approximate(0.1f)
    if (points.size < 6) return false

    var inside = false
    var previousX = points[1]
    var previousY = points[2]
    var index = 3
    while (index + 2 < points.size) {
        val currentX = points[index + 1]
        val currentY = points[index + 2]
        val dx = currentX - previousX
        val dy = currentY - previousY
        val segmentLengthSquared = dx * dx + dy * dy
        if (segmentLengthSquared > 0f) {
            val projection = (((x - previousX) * dx + (y - previousY) * dy) /
                segmentLengthSquared).coerceIn(0f, 1f)
            val projectedX = previousX + projection * dx
            val projectedY = previousY + projection * dy
            val distanceX = x - projectedX
            val distanceY = y - projectedY
            if (distanceX * distanceX + distanceY * distanceY <= 0.01f) {
                return true
            }
        }
        if ((currentY > y) != (previousY > y)) {
            val crossingX = (previousX - currentX) * (y - currentY) /
                (previousY - currentY) + currentX
            if (x < crossingX) inside = !inside
        }
        previousX = currentX
        previousY = currentY
        index += 3
    }
    return inside
}

internal fun containsRoundedPointV2Px(
    x: Float,
    y: Float,
    left: Float,
    top: Float,
    right: Float,
    bottom: Float,
    topLeftRadius: Float,
    topRightRadius: Float,
    bottomRightRadius: Float,
    bottomLeftRadius: Float,
    curveCode: Int,
    isEmpty: Boolean,
): Boolean {
    if (isEmpty || x < left || x > right || y < top || y > bottom) return false

    fun containsCorner(inwardX: Float, inwardY: Float): Boolean {
        if (curveCode == CLIP_CURVE_CIRCULAR) {
            val dx = inwardX - 1f
            val dy = inwardY - 1f
            return dx * dx + dy * dy <= 1f
        }

        // Invert the rendered cubic's inward-x component. This runs only for
        // ACTION_DOWN hit testing, never on the animation/render hot path.
        var low = 0f
        var high = 1f
        repeat(12) {
            val t = (low + high) / 2f
            val inverse = 1f - t
            val boundaryInwardX = inverse * inverse * inverse
            if (boundaryInwardX > inwardX) {
                low = t
            } else {
                high = t
            }
        }
        val t = (low + high) / 2f
        val boundaryInwardY = t * t * t
        return inwardY >= boundaryInwardY
    }

    if (topLeftRadius > 0f && x < left + topLeftRadius && y < top + topLeftRadius) {
        return containsCorner(
            (x - left) / topLeftRadius,
            (y - top) / topLeftRadius,
        )
    }
    if (topRightRadius > 0f && x > right - topRightRadius && y < top + topRightRadius) {
        return containsCorner(
            (right - x) / topRightRadius,
            (y - top) / topRightRadius,
        )
    }
    if (bottomRightRadius > 0f &&
        x > right - bottomRightRadius && y > bottom - bottomRightRadius
    ) {
        return containsCorner(
            (right - x) / bottomRightRadius,
            (bottom - y) / bottomRightRadius,
        )
    }
    if (bottomLeftRadius > 0f && x < left + bottomLeftRadius && y > bottom - bottomLeftRadius) {
        return containsCorner(
            (x - left) / bottomLeftRadius,
            (bottom - y) / bottomLeftRadius,
        )
    }
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
