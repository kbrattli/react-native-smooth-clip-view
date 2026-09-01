#pragma once

#include "SmoothClipRegistry.h"

#include <algorithm>
#include <cmath>

namespace smoothclip {

/**
 * Host-independent canonical clip geometry expressed as edges.
 *
 * The moving aperture is allowed to cross or sit outside any host. Hosts crop
 * the rendered result; they never rewrite the geometry stored by the driver.
 */
struct CanonicalClip {
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
 * Canonicalizes a requested rectangle without consulting host dimensions.
 *
 * Negative dimensions collapse to zero. Corner radii follow the CSS
 * corner-overlap rule against the requested rectangle, using one common scale
 * factor so their proportions are preserved.
 */
inline bool SmoothClipCanonicalize(
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
    CanonicalClip &out) {
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
      (curve != ClipCurve::Circular && curve != ClipCurve::Continuous)) {
    return false;
  }

  const double canonicalWidth = std::max(0.0, width);
  const double canonicalHeight = std::max(0.0, height);
  out.left = x;
  out.top = y;
  out.right = x + canonicalWidth;
  out.bottom = y + canonicalHeight;

  double topLeft = std::max(0.0, resolvedTopLeft);
  double topRight = std::max(0.0, resolvedTopRight);
  double bottomRight = std::max(0.0, resolvedBottomRight);
  double bottomLeft = std::max(0.0, resolvedBottomLeft);
  double scale = 1.0;
  const auto includeLimit = [&scale](double available, double requested) {
    if (requested > 0) scale = std::min(scale, available / requested);
  };
  includeLimit(canonicalWidth, topLeft + topRight);
  includeLimit(canonicalWidth, bottomLeft + bottomRight);
  includeLimit(canonicalHeight, topLeft + bottomLeft);
  includeLimit(canonicalHeight, topRight + bottomRight);
  scale = std::clamp(scale, 0.0, 1.0);

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

inline bool SmoothClipCanonicalize(
    const Geometry &geometry,
    CanonicalClip &out) {
  return SmoothClipCanonicalize(
      geometry.x,
      geometry.y,
      geometry.width,
      geometry.height,
      geometry.radius,
      geometry.topLeftRadius,
      geometry.topRightRadius,
      geometry.bottomRightRadius,
      geometry.bottomLeftRadius,
      geometry.curve,
      out);
}

inline bool SmoothClipCanonicalize(
    double x,
    double y,
    double width,
    double height,
    double radius,
    CanonicalClip &out) {
  return SmoothClipCanonicalize(
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
      out);
}

inline Geometry SmoothClipGeometry(const CanonicalClip &clip) {
  Geometry geometry{
      clip.left,
      clip.top,
      std::max(0.0, clip.right - clip.left),
      std::max(0.0, clip.bottom - clip.top),
      clip.radius};
  geometry.topLeftRadius = clip.topLeftRadius;
  geometry.topRightRadius = clip.topRightRadius;
  geometry.bottomRightRadius = clip.bottomRightRadius;
  geometry.bottomLeftRadius = clip.bottomLeftRadius;
  geometry.curve = clip.curve;
  return geometry;
}

} // namespace smoothclip
