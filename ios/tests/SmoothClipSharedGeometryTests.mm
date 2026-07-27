#import <XCTest/XCTest.h>

#import "SmoothClipGeometry.h"

#include "SmoothClipSharedGeometry.h"

#include <cmath>

// Shared vector table: mirrored in ClipGeometryNormalizerTest.kt so the
// Kotlin legacy path, the shared C++ normalizer (Android driver deliveries),
// and the iOS normalizer provably agree.
typedef struct {
  double x, y, width, height, radius, hostWidth, hostHeight;
  double left, top, right, bottom, normalizedRadius;
} SmoothClipGeometryVector;

@interface SmoothClipSharedGeometryTests : XCTestCase
@end

@implementation SmoothClipSharedGeometryTests

- (void)testSharedNormalizerMatchesTheIOSNormalizerOnAcceptedVectors {
  const SmoothClipGeometryVector vectors[] = {
      {-20, -10, 70, 50, 99, 300, 200, 0, 0, 50, 40, 20},
      {400, 300, 20, 20, 8, 300, 200, 300, 200, 300, 200, 0},
      {50, 50, -10, -20, -4, 300, 200, 50, 50, 50, 50, 0},
      {10, 10, 500, 500, 30, 300, 200, 10, 10, 300, 200, 30},
      {0, 0, 100, 40, 99, 300, 200, 0, 0, 100, 40, 20},
      {5, 5, 20, 20, 10, 0, 0, 0, 0, 0, 0, 0},
      {-50, -50, 20, 20, 5, 300, 200, 0, 0, 0, 0, 0},
  };
  const size_t count = sizeof(vectors) / sizeof(vectors[0]);
  for (size_t index = 0; index < count; index += 1) {
    const SmoothClipGeometryVector vector = vectors[index];
    smoothclip::NormalizedClip shared;
    const bool sharedAccepted = smoothclip::SmoothClipNormalize(
        vector.x, vector.y, vector.width, vector.height, vector.radius,
        vector.hostWidth, vector.hostHeight, shared);
    SmoothNormalizedClipGeometry ios;
    const BOOL iosAccepted = SmoothClipNormalizeGeometry(
        vector.x, vector.y, vector.width, vector.height, vector.radius,
        CGSizeMake(vector.hostWidth, vector.hostHeight), &ios);

    XCTAssertTrue(sharedAccepted, @"vector %zu", index);
    XCTAssertTrue(iosAccepted, @"vector %zu", index);
    XCTAssertEqualWithAccuracy(shared.left, vector.left, 1e-9);
    XCTAssertEqualWithAccuracy(shared.top, vector.top, 1e-9);
    XCTAssertEqualWithAccuracy(shared.right, vector.right, 1e-9);
    XCTAssertEqualWithAccuracy(shared.bottom, vector.bottom, 1e-9);
    XCTAssertEqualWithAccuracy(shared.radius, vector.normalizedRadius, 1e-9);
    // Edge-form output must agree with the iOS rect-form output exactly.
    XCTAssertEqualWithAccuracy(CGRectGetMinX(ios.rect), shared.left, 1e-9);
    XCTAssertEqualWithAccuracy(CGRectGetMinY(ios.rect), shared.top, 1e-9);
    XCTAssertEqualWithAccuracy(CGRectGetMaxX(ios.rect), shared.right, 1e-9);
    XCTAssertEqualWithAccuracy(CGRectGetMaxY(ios.rect), shared.bottom, 1e-9);
    XCTAssertEqualWithAccuracy(ios.radius, shared.radius, 1e-9);
  }
}

- (void)testSharedNormalizerRejectsEveryNonFiniteChannelWithoutWriting {
  const double nan = NAN;
  const double inputs[][7] = {
      {nan, 0, 10, 10, 1, 100, 100},
      {0, nan, 10, 10, 1, 100, 100},
      {0, 0, nan, 10, 1, 100, 100},
      {0, 0, 10, nan, 1, 100, 100},
      {0, 0, 10, 10, nan, 100, 100},
      {0, 0, 10, 10, 1, nan, 100},
      {0, 0, 10, 10, 1, 100, nan},
      {INFINITY, 0, 10, 10, 1, 100, 100},
  };
  const size_t count = sizeof(inputs) / sizeof(inputs[0]);
  for (size_t index = 0; index < count; index += 1) {
    smoothclip::NormalizedClip shared;
    shared.left = -1;
    const bool accepted = smoothclip::SmoothClipNormalize(
        inputs[index][0], inputs[index][1], inputs[index][2], inputs[index][3],
        inputs[index][4], inputs[index][5], inputs[index][6], shared);
    XCTAssertFalse(accepted, @"input %zu", index);
    // Rejection is atomic: the output must not have been written.
    XCTAssertEqual(shared.left, -1.0, @"input %zu", index);
  }
}

@end
