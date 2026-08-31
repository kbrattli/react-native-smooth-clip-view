#pragma once

#include "SmoothClipRegistry.h"

#include <algorithm>
#include <cmath>

namespace smoothclip {

struct NormalizedClip {
  double left = 0;
  double top = 0;
  double right = 0;
  double bottom = 0;
  double radius = 0;
  double topLeftRadius = 0;
  double topRightRadius = 0;
  double bottomRightRadius = 0;
  double bottomLeftRadius = 0;
  ClipCurve curve = ClipCurve::Circular;
};

inline double SmoothClipResolvedRadius(double overrideValue, double radius) {
  return std::isfinite(overrideValue) ? overrideValue : radius;
}

/**
 * Returns true only when host normalization is the identity for this geometry.
 *
 * Timing/keyframe renderers interpolate already-normalized native values on
 * iOS, while Android interpolates presentation scalars and normalizes each
 * delivered frame. Those operations commute exactly when every anchor stays
 * inside one host and the CSS corner-overlap rule never activates. Because
 * each condition below is linear, it also holds for every convex interpolation
 * between accepted anchors.
 *
 * Static clipping deliberately does not use this gate: out-of-bounds geometry
 * remains valid and is still clipped by SmoothClipNormalize.
 */
inline bool SmoothClipGeometryNormalizationIsIdentity(
    const Geometry &geometry,
    double hostWidth,
    double hostHeight) {
  const double topLeft = SmoothClipResolvedRadius(
      geometry.topLeftRadius, geometry.radius);
  const double topRight = SmoothClipResolvedRadius(
      geometry.topRightRadius, geometry.radius);
  const double bottomRight = SmoothClipResolvedRadius(
      geometry.bottomRightRadius, geometry.radius);
  const double bottomLeft = SmoothClipResolvedRadius(
      geometry.bottomLeftRadius, geometry.radius);
  const double right = geometry.x + geometry.width;
  const double bottom = geometry.y + geometry.height;
  const double topRadii = topLeft + topRight;
  const double bottomRadii = bottomLeft + bottomRight;
  const double leftRadii = topLeft + bottomLeft;
  const double rightRadii = topRight + bottomRight;
  const double values[] = {
      geometry.x,
      geometry.y,
      geometry.width,
      geometry.height,
      geometry.radius,
      topLeft,
      topRight,
      bottomRight,
      bottomLeft,
      right,
      bottom,
      topRadii,
      bottomRadii,
      leftRadii,
      rightRadii,
      hostWidth,
      hostHeight,
  };
  for (const double value : values) {
    if (!std::isfinite(value)) return false;
  }
  return hostWidth >= 0 && hostHeight >= 0 &&
      geometry.x >= 0 && geometry.y >= 0 &&
      geometry.width >= 0 && geometry.height >= 0 &&
      right <= hostWidth && bottom <= hostHeight &&
      topLeft >= 0 && topRight >= 0 &&
      bottomRight >= 0 && bottomLeft >= 0 &&
      topRadii <= geometry.width &&
      bottomRadii <= geometry.width &&
      leftRadii <= geometry.height &&
      rightRadii <= geometry.height;
}

inline bool SmoothClipNormalize(
    double x,
    double y,
    double width,
    double height,
    double radius,
    double topLeftRadius,
    double topRightRadius,
    double bottomRightRadius,
    double bottomLeftRadius,
    ClipCurve curve,
    double hostWidth,
    double hostHeight,
    NormalizedClip &out) {
  const double resolvedTopLeft =
      SmoothClipResolvedRadius(topLeftRadius, radius);
  const double resolvedTopRight =
      SmoothClipResolvedRadius(topRightRadius, radius);
  const double resolvedBottomRight =
      SmoothClipResolvedRadius(bottomRightRadius, radius);
  const double resolvedBottomLeft =
      SmoothClipResolvedRadius(bottomLeftRadius, radius);
  if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(width) ||
      !std::isfinite(height) || !std::isfinite(radius) ||
      !std::isfinite(resolvedTopLeft) ||
      !std::isfinite(resolvedTopRight) ||
      !std::isfinite(resolvedBottomRight) ||
      !std::isfinite(resolvedBottomLeft) ||
      !std::isfinite(hostWidth) || !std::isfinite(hostHeight)) {
    return false;
  }

  const double boundedHostWidth = std::max(0.0, hostWidth);
  const double boundedHostHeight = std::max(0.0, hostHeight);
  const double requestedRight = x + std::max(0.0, width);
  const double requestedBottom = y + std::max(0.0, height);
  out.left = std::min(boundedHostWidth, std::max(0.0, x));
  out.top = std::min(boundedHostHeight, std::max(0.0, y));
  out.right = std::min(boundedHostWidth, std::max(0.0, requestedRight));
  out.bottom = std::min(boundedHostHeight, std::max(0.0, requestedBottom));
  const double visibleWidth = std::max(0.0, out.right - out.left);
  const double visibleHeight = std::max(0.0, out.bottom - out.top);

  double topLeft = std::max(0.0, resolvedTopLeft);
  double topRight = std::max(0.0, resolvedTopRight);
  double bottomRight = std::max(0.0, resolvedBottomRight);
  double bottomLeft = std::max(0.0, resolvedBottomLeft);
  double scale = 1.0;
  const auto includeLimit = [&scale](double available, double requested) {
    if (requested > 0) scale = std::min(scale, available / requested);
  };
  includeLimit(visibleWidth, topLeft + topRight);
  includeLimit(visibleWidth, bottomLeft + bottomRight);
  includeLimit(visibleHeight, topLeft + bottomLeft);
  includeLimit(visibleHeight, topRight + bottomRight);
  scale = std::max(0.0, std::min(1.0, scale));
  out.topLeftRadius = topLeft * scale;
  out.topRightRadius = topRight * scale;
  out.bottomRightRadius = bottomRight * scale;
  out.bottomLeftRadius = bottomLeft * scale;
  const bool uniform = out.topLeftRadius == out.topRightRadius &&
      out.topLeftRadius == out.bottomRightRadius &&
      out.topLeftRadius == out.bottomLeftRadius;
  out.radius = uniform ? out.topLeftRadius : 0.0;
  out.curve = curve;
  return true;
}

// Shared clip normalization emitting edges (Android's Outline consumes
// edges). Mirrors ios/SmoothClipGeometry.h (SmoothClipNormalizeGeometry) and
// ClipGeometryNormalizer.kt (normalizeClipGeometryPx); a change here must
// land in all three.
inline bool SmoothClipNormalize(
    double x,
    double y,
    double width,
    double height,
    double radius,
    double hostWidth,
    double hostHeight,
    NormalizedClip &out) {
  return SmoothClipNormalize(
      x,
      y,
      width,
      height,
      radius,
      radius,
      radius,
      radius,
      radius,
      ClipCurve::Circular,
      hostWidth,
      hostHeight,
      out);
}

} // namespace smoothclip
