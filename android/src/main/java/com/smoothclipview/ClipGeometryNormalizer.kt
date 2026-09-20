package com.smoothclipview

import android.graphics.Path
import android.view.View
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.tan

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
 * Figma corner smoothing used by the continuous curve. 0.6 is the value Figma
 * tuned against iOS continuous corners, and it is fixed so that every corner
 * parameter below is a compile-time constant.
 */
private const val CONTINUOUS_SMOOTHING = 0.6f

// Unit-radius Figma parameters at CONTINUOUS_SMOOTHING. They are linear in the
// radius while the shoulder fits its budget, so the per-frame rebuild does no
// trigonometry. Derivation, with arc = 90deg * (1 - s) and beta = 45deg * s:
//   ARC_CHORD = sqrt(2) * sin(arc / 2)      axis distance covered by the arc
//   C = tan(beta / 2) * cos(beta),  D = tan(beta / 2) * sin(beta)
//   B = (1 + s - ARC_CHORD - C - D) / 3,    A = 2 * B
//   ARC_HANDLE = 4/3 * tan(arc / 4)         cubic handle of the circular arc
private const val CONTINUOUS_A = 0.5600525f
private const val CONTINUOUS_B = 0.28002625f
private const val CONTINUOUS_C = 0.21391174f
private const val CONTINUOUS_D = 0.10899348f
private const val CONTINUOUS_ARC_CHORD = 0.43701602f
private const val CONTINUOUS_ARC_HANDLE = 0.21117925f
private const val CONTINUOUS_COS_BETA = 0.8910065f
private const val CONTINUOUS_SIN_BETA = 0.4539905f
private const val QUARTER_PI = 0.7853982f
private const val SQRT_2 = 1.4142135f

/**
 * Emits one rounded rectangle. Circular uses the standard quarter-circle
 * cubic per corner. Continuous is the Figma smoothed corner at smoothing 0.6:
 * a cubic shoulder that leaves the edge at 1.6 * radius, the real radius-R
 * circle through the apex, and a mirrored shoulder. The apex therefore sits
 * where a circular corner's does; only the shoulders are longer and eased. It
 * is the same family as Apple's continuous corner, not pixel-identical to it.
 *
 * This runs every animation frame: it allocates nothing, and a continuous
 * corner is always three cubics (the arc included), whatever its radius.
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
    if (curveCode == CLIP_CURVE_CONTINUOUS) {
        val width = right - left
        val height = bottom - top
        appendContinuousCorner(
            path, true, right, top, 1f, 0f, 0f, 1f, topRightRadius,
            continuousBudget(
                topRightRadius, topLeftRadius, width, bottomRightRadius, height,
            ),
        )
        appendContinuousCorner(
            path, false, right, bottom, 0f, 1f, -1f, 0f, bottomRightRadius,
            continuousBudget(
                bottomRightRadius, topRightRadius, height, bottomLeftRadius, width,
            ),
        )
        appendContinuousCorner(
            path, false, left, bottom, -1f, 0f, 0f, -1f, bottomLeftRadius,
            continuousBudget(
                bottomLeftRadius, bottomRightRadius, width, topLeftRadius, height,
            ),
        )
        appendContinuousCorner(
            path, false, left, top, 0f, -1f, 1f, 0f, topLeftRadius,
            continuousBudget(
                topLeftRadius, bottomLeftRadius, height, topRightRadius, width,
            ),
        )
        path.close()
        return
    }

    val coefficient = 0.5522848f

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
 * Edge length one corner's shoulder may use. Each side is shared with the
 * neighbouring corner in proportion to the radii, so two shoulders never
 * overlap. Uniform radii give min(width, height) / 2, Figma's own budget.
 */
private fun continuousBudget(
    radius: Float,
    incomingNeighbourRadius: Float,
    incomingSide: Float,
    outgoingNeighbourRadius: Float,
    outgoingSide: Float,
): Float {
    val incoming = if (incomingNeighbourRadius > 0f) {
        incomingSide * radius / (radius + incomingNeighbourRadius)
    } else {
        incomingSide
    }
    val outgoing = if (outgoingNeighbourRadius > 0f) {
        outgoingSide * radius / (radius + outgoingNeighbourRadius)
    } else {
        outgoingSide
    }
    return min(incoming, outgoing)
}

/**
 * Appends one continuous corner, travelling clockwise. (ux, uy) is the unit
 * direction of the edge running into the corner point and (vx, vy) of the edge
 * leaving it, so one body serves all four orientations.
 */
private fun appendContinuousCorner(
    path: Path,
    isFirst: Boolean,
    cornerX: Float,
    cornerY: Float,
    ux: Float,
    uy: Float,
    vx: Float,
    vy: Float,
    radius: Float,
    budget: Float,
) {
    if (radius <= 0f) {
        // A plain vertex: an all-square clip stays a rectangle the renderer
        // can recognise, instead of a path of degenerate curves.
        if (isFirst) path.moveTo(cornerX, cornerY) else path.lineTo(cornerX, cornerY)
        return
    }

    val shoulder: Float
    val a: Float
    val b: Float
    val c: Float
    val d: Float
    val arcChord: Float
    val arcHandle: Float
    val cosBeta: Float
    val sinBeta: Float
    if ((1f + CONTINUOUS_SMOOTHING) * radius <= budget) {
        shoulder = (1f + CONTINUOUS_SMOOTHING) * radius
        a = CONTINUOUS_A * radius
        b = CONTINUOUS_B * radius
        c = CONTINUOUS_C * radius
        d = CONTINUOUS_D * radius
        arcChord = CONTINUOUS_ARC_CHORD * radius
        arcHandle = CONTINUOUS_ARC_HANDLE * radius
        cosBeta = CONTINUOUS_COS_BETA
        sinBeta = CONTINUOUS_SIN_BETA
    } else {
        // The shoulder does not fit (near-pill shapes). Figma reduces the
        // smoothing until it does; at zero this is an exact circular corner.
        shoulder = max(budget, radius)
        val smoothing = (shoulder / radius - 1f)
            .coerceIn(0f, CONTINUOUS_SMOOTHING)
        val beta = QUARTER_PI * smoothing
        val halfArc = QUARTER_PI * (1f - smoothing)
        val tanHalfBeta = tan(beta / 2f)
        cosBeta = cos(beta)
        sinBeta = sin(beta)
        c = radius * tanHalfBeta * cosBeta
        d = radius * tanHalfBeta * sinBeta
        arcChord = radius * SQRT_2 * sin(halfArc)
        arcHandle = radius * (4f / 3f) * tan(halfArc / 2f)
        b = (shoulder - arcChord - c - d) / 3f
        a = 2f * b
    }

    val startX = cornerX - ux * shoulder
    val startY = cornerY - uy * shoulder
    if (isFirst) path.moveTo(startX, startY) else path.lineTo(startX, startY)

    val arcStartX = startX + ux * (a + b + c) + vx * d
    val arcStartY = startY + uy * (a + b + c) + vy * d
    path.cubicTo(
        startX + ux * a,
        startY + uy * a,
        startX + ux * (a + b),
        startY + uy * (a + b),
        arcStartX,
        arcStartY,
    )

    val arcEndX = arcStartX + (ux + vx) * arcChord
    val arcEndY = arcStartY + (uy + vy) * arcChord
    path.cubicTo(
        arcStartX + (ux * cosBeta + vx * sinBeta) * arcHandle,
        arcStartY + (uy * cosBeta + vy * sinBeta) * arcHandle,
        arcEndX - (ux * sinBeta + vx * cosBeta) * arcHandle,
        arcEndY - (uy * sinBeta + vy * cosBeta) * arcHandle,
        arcEndX,
        arcEndY,
    )

    path.cubicTo(
        arcEndX + ux * d + vx * c,
        arcEndY + uy * d + vy * c,
        arcEndX + ux * d + vx * (b + c),
        arcEndY + uy * d + vy * (b + c),
        cornerX + vx * shoulder,
        cornerY + vy * shoulder,
    )
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

/** Conservative for rounded corners, exact for the rotated bounding rectangle. */
internal fun rotatedRectIntersectsHost(
    left: Double, top: Double, right: Double, bottom: Double,
    pivotX: Double, pivotY: Double, rotation: Double, hostWidth: Double, hostHeight: Double,
): Boolean {
    if (right <= left || bottom <= top || hostWidth <= 0 || hostHeight <= 0) return false
    if (rotation == 0.0) return right > 0 && bottom > 0 && left < hostWidth && top < hostHeight
    val c = kotlin.math.cos(rotation)
    val s = kotlin.math.sin(rotation)
    val dx = (left + right) / 2 - pivotX
    val dy = (top + bottom) / 2 - pivotY
    val x = pivotX + c * dx - s * dy - hostWidth / 2
    val y = pivotY + s * dx + c * dy - hostHeight / 2
    val hw = (right - left) / 2
    val hh = (bottom - top) / 2
    val ac = kotlin.math.abs(c)
    val ass = kotlin.math.abs(s)
    return kotlin.math.abs(x) < hostWidth / 2 + ac * hw + ass * hh &&
        kotlin.math.abs(y) < hostHeight / 2 + ass * hw + ac * hh &&
        kotlin.math.abs(c * x + s * y) < hw + ac * hostWidth / 2 + ass * hostHeight / 2 &&
        kotlin.math.abs(-s * x + c * y) < hh + ass * hostWidth / 2 + ac * hostHeight / 2
}
