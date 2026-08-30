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
  // Retained for the V1 uniform-radius contract. V2 callers should consume
  // `radii`; this field is zero when the normalized radii are unequal.
  CGFloat radius;
  SmoothClipCornerRadii radii;
  SmoothClipCornerCurve curve;
} SmoothNormalizedClipGeometry;

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
 * Normalizes the V2 rectangle and four radii without allocating.
 *
 * The proportional overlap rule matches CSS border radii and the shared
 * Android/C++ contract: all corners use one scale factor, preserving their
 * relative shape while no opposing pair exceeds its edge.
 */
NS_INLINE BOOL SmoothClipNormalizeGeometryV2(
    CGFloat x,
    CGFloat y,
    CGFloat width,
    CGFloat height,
    CGFloat topLeftRadius,
    CGFloat topRightRadius,
    CGFloat bottomRightRadius,
    CGFloat bottomLeftRadius,
    NSInteger curveCode,
    CGSize hostSize,
    SmoothNormalizedClipGeometry *result) {
  if (!isfinite(x) || !isfinite(y) || !isfinite(width) ||
      !isfinite(height) || !isfinite(topLeftRadius) ||
      !isfinite(topRightRadius) || !isfinite(bottomRightRadius) ||
      !isfinite(bottomLeftRadius) || !isfinite(hostSize.width) ||
      !isfinite(hostSize.height) ||
      (curveCode != SmoothClipCornerCurveCircular &&
       curveCode != SmoothClipCornerCurveContinuous)) {
    return NO;
  }

  const CGFloat hostWidth = MAX(0, hostSize.width);
  const CGFloat hostHeight = MAX(0, hostSize.height);
  const CGFloat requestedWidth = MAX(0, width);
  const CGFloat requestedHeight = MAX(0, height);
  const CGFloat requestedRight = x + requestedWidth;
  const CGFloat requestedBottom = y + requestedHeight;
  const CGFloat left = MIN(hostWidth, MAX(0, x));
  const CGFloat top = MIN(hostHeight, MAX(0, y));
  const CGFloat right = MIN(hostWidth, MAX(0, requestedRight));
  const CGFloat bottom = MIN(hostHeight, MAX(0, requestedBottom));
  const CGFloat visibleWidth = MAX(0, right - left);
  const CGFloat visibleHeight = MAX(0, bottom - top);

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
                  visibleWidth, radii.topLeft, radii.topRight),
              SmoothClipSafeOverlapFactor(
                  visibleWidth, radii.bottomLeft, radii.bottomRight)),
          MIN(
              SmoothClipSafeOverlapFactor(
                  visibleHeight, radii.topLeft, radii.bottomLeft),
              SmoothClipSafeOverlapFactor(
                  visibleHeight, radii.topRight, radii.bottomRight))));
  radii.topLeft *= overlapScale;
  radii.topRight *= overlapScale;
  radii.bottomRight *= overlapScale;
  radii.bottomLeft *= overlapScale;

  result->rect = CGRectMake(left, top, visibleWidth, visibleHeight);
  result->radii = radii;
  result->radius = SmoothClipCornerRadiiAreUniform(radii)
      ? radii.topLeft
      : 0;
  result->curve = (SmoothClipCornerCurve)curveCode;
  return YES;
}

/** Mirrors the Android and JavaScript geometry contract without allocating. */
NS_INLINE BOOL SmoothClipNormalizeGeometry(
    CGFloat x,
    CGFloat y,
    CGFloat width,
    CGFloat height,
    CGFloat radius,
    CGSize hostSize,
    SmoothNormalizedClipGeometry *result) {
  return SmoothClipNormalizeGeometryV2(
      x,
      y,
      width,
      height,
      radius,
      radius,
      radius,
      radius,
      SmoothClipCornerCurveCircular,
      hostSize,
      result);
}

/**
 * Creates the stable nine-segment rounded-rectangle topology used by the
 * unequal-corner CAShapeLayer mask. Every corner is one cubic, including a
 * zero-radius corner, so Core Animation can interpolate paths without a
 * topology change.
 */
NS_INLINE CGPathRef SmoothClipCreateRoundedRectPath(
    CGRect rect,
    SmoothClipCornerRadii radii,
    SmoothClipCornerCurve curve) CF_RETURNS_RETAINED {
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

  CGMutablePathRef path = CGPathCreateMutable();
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
