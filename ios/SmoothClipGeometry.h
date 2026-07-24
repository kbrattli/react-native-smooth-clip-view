#import <CoreGraphics/CoreGraphics.h>

#include <math.h>

typedef struct {
  CGRect rect;
  CGFloat radius;
} SmoothNormalizedClipGeometry;

/** Mirrors the Android and JavaScript geometry contract without allocating. */
NS_INLINE BOOL SmoothClipNormalizeGeometry(
    CGFloat x,
    CGFloat y,
    CGFloat width,
    CGFloat height,
    CGFloat radius,
    CGSize hostSize,
    SmoothNormalizedClipGeometry *result) {
  if (!isfinite(x) || !isfinite(y) || !isfinite(width) ||
      !isfinite(height) || !isfinite(radius) ||
      !isfinite(hostSize.width) || !isfinite(hostSize.height)) {
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

  result->rect = CGRectMake(left, top, visibleWidth, visibleHeight);
  result->radius = MIN(MAX(0, radius), MIN(visibleWidth, visibleHeight) / 2.0);
  return YES;
}
