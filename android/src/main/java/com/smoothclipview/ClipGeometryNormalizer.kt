package com.smoothclipview

import android.view.View
import kotlin.math.max
import kotlin.math.min

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
