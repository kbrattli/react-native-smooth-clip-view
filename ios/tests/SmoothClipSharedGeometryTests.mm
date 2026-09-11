#import <XCTest/XCTest.h>

#import "SmoothClipGeometry.h"

#include "SmoothClipAnimationCurve.h"
#include "SmoothClipSharedGeometry.h"

#include <cmath>
#include <cfloat>

// Mirrored in ClipGeometryNormalizerTest.kt so Kotlin, shared C++, and iOS
// provably use the same host-independent canonical geometry.
typedef struct {
  double x, y, width, height, radius;
  double left, top, right, bottom, canonicalRadius;
} SmoothClipGeometryVector;

@interface SmoothClipSharedGeometryTests : XCTestCase
@end

@implementation SmoothClipSharedGeometryTests

- (void)testSharedCanonicalizerMatchesTheIOSCanonicalizer {
  const SmoothClipGeometryVector vectors[] = {
      {-20, -10, 70, 50, 99, -20, -10, 50, 40, 25},
      {400, 300, 20, 20, 8, 400, 300, 420, 320, 8},
      {50, 50, -10, -20, -4, 50, 50, 50, 50, 0},
      {10, 10, 500, 500, 30, 10, 10, 510, 510, 30},
      {0, 0, 100, 40, 99, 0, 0, 100, 40, 20},
      {5, 5, 20, 20, 10, 5, 5, 25, 25, 10},
      {-50, -50, 20, 20, 5, -50, -50, -30, -30, 5},
  };
  const size_t count = sizeof(vectors) / sizeof(vectors[0]);
  for (size_t index = 0; index < count; index += 1) {
    const SmoothClipGeometryVector vector = vectors[index];
    smoothclip::CanonicalClip shared;
    const bool sharedAccepted = smoothclip::SmoothClipCanonicalize(
        vector.x, vector.y, vector.width, vector.height, vector.radius, shared);
    SmoothClipCanonicalGeometry ios;
    const BOOL iosAccepted = SmoothClipCanonicalizeGeometry(
        vector.x, vector.y, vector.width, vector.height, vector.radius, &ios);

    XCTAssertTrue(sharedAccepted, @"vector %zu", index);
    XCTAssertTrue(iosAccepted, @"vector %zu", index);
    XCTAssertEqualWithAccuracy(shared.left, vector.left, 1e-9);
    XCTAssertEqualWithAccuracy(shared.top, vector.top, 1e-9);
    XCTAssertEqualWithAccuracy(shared.right, vector.right, 1e-9);
    XCTAssertEqualWithAccuracy(shared.bottom, vector.bottom, 1e-9);
    XCTAssertEqualWithAccuracy(shared.radius, vector.canonicalRadius, 1e-9);
    XCTAssertEqualWithAccuracy(CGRectGetMinX(ios.rect), shared.left, 1e-9);
    XCTAssertEqualWithAccuracy(CGRectGetMinY(ios.rect), shared.top, 1e-9);
    XCTAssertEqualWithAccuracy(CGRectGetMaxX(ios.rect), shared.right, 1e-9);
    XCTAssertEqualWithAccuracy(CGRectGetMaxY(ios.rect), shared.bottom, 1e-9);
    XCTAssertEqualWithAccuracy(ios.radius, shared.radius, 1e-9);
  }
}

- (void)testSharedCanonicalizerRejectsEveryNonFiniteChannelAtomically {
  const double nan = NAN;
  const double inputs[][5] = {
      {nan, 0, 10, 10, 1},
      {0, nan, 10, 10, 1},
      {0, 0, nan, 10, 1},
      {0, 0, 10, nan, 1},
      {0, 0, 10, 10, nan},
      {INFINITY, 0, 10, 10, 1},
  };
  const size_t count = sizeof(inputs) / sizeof(inputs[0]);
  for (size_t index = 0; index < count; index += 1) {
    smoothclip::CanonicalClip shared;
    shared.left = -1;
    const bool accepted = smoothclip::SmoothClipCanonicalize(
        inputs[index][0], inputs[index][1], inputs[index][2], inputs[index][3],
        inputs[index][4], shared);
    XCTAssertFalse(accepted, @"input %zu", index);
    XCTAssertEqual(shared.left, -1.0, @"input %zu", index);
  }
}

- (void)testSharedCanonicalizerRejectsArithmeticOverflow {
  smoothclip::CanonicalClip shared;
  XCTAssertFalse(smoothclip::SmoothClipCanonicalize(
      DBL_MAX, 0, DBL_MAX, 10, 1, shared));
  XCTAssertFalse(smoothclip::SmoothClipCanonicalize(
      0, DBL_MAX, 10, DBL_MAX, 1, shared));
}

- (void)testCanonicalPresentationKeepsRawCoordinatesAndScalesRadiiOnly {
  smoothclip::Presentation presentation{{-20, 180, 30, 20, 40}, 7, -9, 1};

  XCTAssertTrue(smoothclip::canonicalizePresentation(presentation));
  XCTAssertEqualWithAccuracy(presentation.clip.x, -20, 1e-9);
  XCTAssertEqualWithAccuracy(presentation.clip.y, 180, 1e-9);
  XCTAssertEqualWithAccuracy(presentation.clip.width, 30, 1e-9);
  XCTAssertEqualWithAccuracy(presentation.clip.height, 20, 1e-9);
  XCTAssertEqualWithAccuracy(presentation.clip.radius, 10, 1e-9);
  XCTAssertEqualWithAccuracy(presentation.contentTranslateX, 7, 1e-9);
  XCTAssertEqualWithAccuracy(presentation.contentTranslateY, -9, 1e-9);
}


- (void)testRotationUsesRotatedViewportIntersectionAndPreservesTurns {
  XCTAssertFalse(smoothclip::rotatedRectIntersectsHost(-30, 0, 20, 100, 0, 100, 100));
  XCTAssertTrue(smoothclip::rotatedRectIntersectsHost(-30, 0, 20, 100, M_PI_2, 100, 100));
  XCTAssertFalse(smoothclip::rotatedRectIntersectsHost(-100, -100, 10, 10, M_PI_4, 100, 100));
  XCTAssertEqualWithAccuracy(smoothclip::unwrapRotation(M_PI_2, 4.5 * M_PI), 4.5 * M_PI, 1e-10);
  XCTAssertEqualWithAccuracy(smoothclip::unwrapRotation(-M_PI_2, -4.5 * M_PI), -4.5 * M_PI, 1e-10);
}

- (void)testAppearanceChannelsAnimateWithoutAShadowAndClampOnlyRenderedOpacity {
  smoothclip::Presentation from{{0, 0, 80, 60, 8}, 0, 0};
  auto to = from;
  to.rotation = 4 * M_PI;
  to.opacity = 0;
  const auto middle = smoothclip::interpolate(from, to, 0.5);
  XCTAssertEqualWithAccuracy(middle.rotation, 2 * M_PI, 1e-10);
  XCTAssertEqualWithAccuracy(middle.opacity, 0.5, 1e-10);
  auto channels = smoothclip::toChannels(to);
  channels[12] = -0.25;
  const auto rendered = smoothclip::fromChannels(channels);
  XCTAssertEqual(rendered.opacity, 0);
  XCTAssertEqual(channels[12], -0.25);
  to.opacity = NAN;
  XCTAssertFalse(smoothclip::canonicalizePresentation(to));
  to.opacity = 1;
  to.rotation = INFINITY;
  XCTAssertFalse(smoothclip::canonicalizePresentation(to));
}

@end
