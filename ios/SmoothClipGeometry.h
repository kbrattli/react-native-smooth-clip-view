#import <CoreGraphics/CoreGraphics.h>

#include <math.h>

typedef struct {
  CGFloat topLeft;
  CGFloat topRight;
  CGFloat bottomRight;
  CGFloat bottomLeft;
} SmoothClipCornerRadii;

typedef NS_ENUM(NSInteger, SmoothClipCornerCurve) {
  SmoothClipCornerCurveCircular = 0,
  SmoothClipCornerCurveContinuous = 1,
};

typedef struct {
  CGRect rect;
  // Uniform-radius fast-path value; zero when canonical radii are unequal.
  CGFloat radius;
  SmoothClipCornerRadii radii;
  SmoothClipCornerCurve curve;
} SmoothClipCanonicalGeometry;

NS_INLINE BOOL SmoothClipCornerRadiiEqual(
    SmoothClipCornerRadii first,
    SmoothClipCornerRadii second) {
  return first.topLeft == second.topLeft &&
      first.topRight == second.topRight &&
      first.bottomRight == second.bottomRight &&
      first.bottomLeft == second.bottomLeft;
}

NS_INLINE BOOL SmoothClipCornerRadiiAreUniform(
    SmoothClipCornerRadii radii) {
  return radii.topLeft == radii.topRight &&
      radii.topLeft == radii.bottomRight &&
      radii.topLeft == radii.bottomLeft;
}

NS_INLINE CGFloat SmoothClipSafeOverlapFactor(
    CGFloat extent,
    CGFloat firstRadius,
    CGFloat secondRadius) {
  const CGFloat sum = firstRadius + secondRadius;
  return sum > 0 ? extent / sum : 1;
}

/**
 * Canonicalizes the rectangle and four radii without allocating.
 *
 * The proportional overlap rule matches CSS border radii and the shared
 * Android/C++ contract: all corners use one scale factor, preserving their
 * relative shape while no opposing pair exceeds its edge.
 */
NS_INLINE BOOL SmoothClipCanonicalizeGeometry(
    CGFloat x,
    CGFloat y,
    CGFloat width,
    CGFloat height,
    CGFloat topLeftRadius,
    CGFloat topRightRadius,
    CGFloat bottomRightRadius,
    CGFloat bottomLeftRadius,
    NSInteger curveCode,
    SmoothClipCanonicalGeometry *result) {
  if (!isfinite(x) || !isfinite(y) || !isfinite(width) ||
      !isfinite(height) || !isfinite(topLeftRadius) ||
      !isfinite(topRightRadius) || !isfinite(bottomRightRadius) ||
      !isfinite(bottomLeftRadius) ||
      (curveCode != SmoothClipCornerCurveCircular &&
       curveCode != SmoothClipCornerCurveContinuous)) {
    return NO;
  }

  const CGFloat requestedWidth = MAX(0, width);
  const CGFloat requestedHeight = MAX(0, height);
  if (!isfinite(x + requestedWidth) || !isfinite(y + requestedHeight)) {
    return NO;
  }

  SmoothClipCornerRadii radii = {
      MAX(0, topLeftRadius),
      MAX(0, topRightRadius),
      MAX(0, bottomRightRadius),
      MAX(0, bottomLeftRadius),
  };
  const CGFloat overlapScale = MIN(
      1,
      MIN(
          MIN(
              SmoothClipSafeOverlapFactor(
                  requestedWidth, radii.topLeft, radii.topRight),
              SmoothClipSafeOverlapFactor(
                  requestedWidth, radii.bottomLeft, radii.bottomRight)),
          MIN(
              SmoothClipSafeOverlapFactor(
                  requestedHeight, radii.topLeft, radii.bottomLeft),
              SmoothClipSafeOverlapFactor(
                  requestedHeight, radii.topRight, radii.bottomRight))));
  radii.topLeft *= overlapScale;
  radii.topRight *= overlapScale;
  radii.bottomRight *= overlapScale;
  radii.bottomLeft *= overlapScale;

  result->rect = CGRectMake(x, y, requestedWidth, requestedHeight);
  result->radii = radii;
  result->radius = SmoothClipCornerRadiiAreUniform(radii)
      ? radii.topLeft
      : 0;
  result->curve = (SmoothClipCornerCurve)curveCode;
  return YES;
}

/** Mirrors the Android and JavaScript geometry contract without allocating. */
NS_INLINE BOOL SmoothClipCanonicalizeGeometry(
    CGFloat x,
    CGFloat y,
    CGFloat width,
    CGFloat height,
    CGFloat radius,
    SmoothClipCanonicalGeometry *result) {
  return SmoothClipCanonicalizeGeometry(
      x,
      y,
      width,
      height,
      radius,
      radius,
      radius,
      radius,
      SmoothClipCornerCurveCircular,
      result);
}

/**
 * Creates an empty path for an empty clip. Non-empty rounded rectangles use a
 * stable nine-segment topology. Every corner is one cubic, including a
 * zero-radius corner, so Core Animation can interpolate non-empty paths
 * without a topology change.
 */
NS_INLINE CGPathRef SmoothClipCreateRoundedRectPath(
    CGRect rect,
    SmoothClipCornerRadii radii,
    SmoothClipCornerCurve curve) CF_RETURNS_RETAINED {
  CGMutablePathRef path = CGPathCreateMutable();
  if (CGRectIsEmpty(rect)) return path;
  const CGFloat minX = CGRectGetMinX(rect);
  const CGFloat minY = CGRectGetMinY(rect);
  const CGFloat maxX = CGRectGetMaxX(rect);
  const CGFloat maxY = CGRectGetMaxY(rect);
  // Circular is the exact cubic-circle coefficient. The portable continuous
  // fallback uses kappa=1 so each cubic joins its straight edges with zero
  // curvature, matching the portable Android path. Hit testing derives
  // from this rendered path rather than maintaining a second curve model.
  // Uniform
  // continuous shapes use CALayer.cornerCurve for Apple's platform-native
  // compositor shape and are intentionally not pixel-identical cross-platform.
  const CGFloat controlFactor =
      curve == SmoothClipCornerCurveContinuous
      ? 1.0
      : 0.5522847498307936;

  CGPathMoveToPoint(path, NULL, minX + radii.topLeft, minY);
  CGPathAddLineToPoint(path, NULL, maxX - radii.topRight, minY);
  CGPathAddCurveToPoint(
      path,
      NULL,
      maxX - radii.topRight + radii.topRight * controlFactor,
      minY,
      maxX,
      minY + radii.topRight - radii.topRight * controlFactor,
      maxX,
      minY + radii.topRight);
  CGPathAddLineToPoint(path, NULL, maxX, maxY - radii.bottomRight);
  CGPathAddCurveToPoint(
      path,
      NULL,
      maxX,
      maxY - radii.bottomRight + radii.bottomRight * controlFactor,
      maxX - radii.bottomRight +
          radii.bottomRight * controlFactor,
      maxY,
      maxX - radii.bottomRight,
      maxY);
  CGPathAddLineToPoint(path, NULL, minX + radii.bottomLeft, maxY);
  CGPathAddCurveToPoint(
      path,
      NULL,
      minX + radii.bottomLeft - radii.bottomLeft * controlFactor,
      maxY,
      minX,
      maxY - radii.bottomLeft + radii.bottomLeft * controlFactor,
      minX,
      maxY - radii.bottomLeft);
  CGPathAddLineToPoint(path, NULL, minX, minY + radii.topLeft);
  CGPathAddCurveToPoint(
      path,
      NULL,
      minX,
      minY + radii.topLeft - radii.topLeft * controlFactor,
      minX + radii.topLeft - radii.topLeft * controlFactor,
      minY,
      minX + radii.topLeft,
      minY);
  CGPathCloseSubpath(path);
  return path;
}
