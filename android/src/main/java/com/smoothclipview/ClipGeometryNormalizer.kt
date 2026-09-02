package com.smoothclipview

import android.graphics.Path
import android.view.View
import kotlin.math.max
import kotlin.math.min

internal const val CLIP_CURVE_CIRCULAR = 0
internal const val CLIP_CURVE_CONTINUOUS = 1

/**
 * Canonicalizes raw clip geometry without allocating a result object. Host
 * bounds deliberately do not participate; SmoothClipView crops at draw time.
 */
internal inline fun canonicalizeClipGeometryPx(
    x: Float,
    y: Float,
    width: Float,
    height: Float,
    radius: Float,
    apply: (
        left: Float,
        top: Float,
        right: Float,
        bottom: Float,
        radius: Float,
    ) -> Unit,
): Boolean {
    if (!x.isFinite() || !y.isFinite() || !width.isFinite() ||
        !height.isFinite() || !radius.isFinite()
    ) {
        return false
    }

    val canonicalWidth = max(0f, width)
    val canonicalHeight = max(0f, height)
    val right = x + canonicalWidth
    val bottom = y + canonicalHeight
    if (!right.isFinite() || !bottom.isFinite()) return false
    val canonicalRadius = min(
        radius.coerceAtLeast(0f),
        min(canonicalWidth, canonicalHeight) / 2f,
    )

    apply(x, y, right, bottom, canonicalRadius)
    return true
}

/**
 * Canonicalization with independent radii. Radii use the CSS overlap rule:
 * one shared factor keeps all four corners proportional when any opposing pair
 * exceeds the requested width or height. This mirrors
 * SmoothClipCanonicalize in the shared C++ delivery path.
 */
internal inline fun canonicalizeClipGeometryPx(
    x: Float,
    y: Float,
    width: Float,
    height: Float,
    topLeftRadius: Float,
    topRightRadius: Float,
    bottomRightRadius: Float,
    bottomLeftRadius: Float,
    curveCode: Int,
    apply: (
        left: Float,
        top: Float,
        right: Float,
        bottom: Float,
        canonicalTopLeftRadius: Float,
        canonicalTopRightRadius: Float,
        canonicalBottomRightRadius: Float,
        canonicalBottomLeftRadius: Float,
        canonicalCurveCode: Int,
    ) -> Unit,
): Boolean {
    if (!x.isFinite() || !y.isFinite() || !width.isFinite() ||
        !height.isFinite() || !topLeftRadius.isFinite() ||
        !topRightRadius.isFinite() || !bottomRightRadius.isFinite() ||
        !bottomLeftRadius.isFinite() ||
        (curveCode != CLIP_CURVE_CIRCULAR && curveCode != CLIP_CURVE_CONTINUOUS)
    ) {
        return false
    }

    val canonicalWidth = max(0f, width)
    val canonicalHeight = max(0f, height)
    val right = x + canonicalWidth
    val bottom = y + canonicalHeight
    if (!right.isFinite() || !bottom.isFinite()) return false
    val topLeft = topLeftRadius.coerceAtLeast(0f)
    val topRight = topRightRadius.coerceAtLeast(0f)
    val bottomRight = bottomRightRadius.coerceAtLeast(0f)
    val bottomLeft = bottomLeftRadius.coerceAtLeast(0f)

    var radiusScale = 1f
    val topWidth = topLeft + topRight
    val bottomWidth = bottomLeft + bottomRight
    val leftHeight = topLeft + bottomLeft
    val rightHeight = topRight + bottomRight
    if (topWidth > 0f) radiusScale = min(radiusScale, canonicalWidth / topWidth)
    if (bottomWidth > 0f) radiusScale = min(radiusScale, canonicalWidth / bottomWidth)
    if (leftHeight > 0f) radiusScale = min(radiusScale, canonicalHeight / leftHeight)
    if (rightHeight > 0f) radiusScale = min(radiusScale, canonicalHeight / rightHeight)
    radiusScale = radiusScale.coerceIn(0f, 1f)

    apply(
        x,
        y,
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
 * Emits one fixed-topology rounded rectangle for both curve families.
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

internal fun renderVisibility(rendersIntoHost: Boolean): Int =
    if (rendersIntoHost) View.VISIBLE else View.INVISIBLE

internal fun clipAccessibility(
    isEmpty: Boolean,
    requestedAccessibility: Int,
): Int =
    if (isEmpty) {
        View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
    } else {
        requestedAccessibility
    }
