#pragma once

#include <algorithm>
#include <cmath>

namespace smoothclip {

struct NormalizedClip {
  double left = 0;
  double top = 0;
  double right = 0;
  double bottom = 0;
  double radius = 0;
};

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
  if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(width) ||
      !std::isfinite(height) || !std::isfinite(radius) ||
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
  out.radius = std::min(
      std::max(0.0, radius), std::min(visibleWidth, visibleHeight) / 2.0);
  return true;
}

} // namespace smoothclip
