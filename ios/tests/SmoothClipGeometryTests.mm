#import <XCTest/XCTest.h>

#import "../SmoothClipGeometry.h"

@interface SmoothClipGeometryTests : XCTestCase
@end

@implementation SmoothClipGeometryTests

static void CountPathElements(
    void *context,
    const CGPathElement *element) {
  (void)element;
  NSUInteger *count = static_cast<NSUInteger *>(context);
  *count += 1;
}

- (void)testIntersectsGeometryAndClampsRadius {
  SmoothNormalizedClipGeometry result;

  XCTAssertTrue(SmoothClipNormalizeGeometry(
      -20, -10, 70, 50, 99, CGSizeMake(300, 200), &result));
  XCTAssertTrue(CGRectEqualToRect(result.rect, CGRectMake(0, 0, 50, 40)));
  XCTAssertEqual(result.radius, 20);
}

- (void)testProducesAnEmptyClipOutsideTheHost {
  SmoothNormalizedClipGeometry result;

  XCTAssertTrue(SmoothClipNormalizeGeometry(
      400, 300, 20, 20, 8, CGSizeMake(300, 200), &result));
  XCTAssertTrue(CGRectEqualToRect(result.rect, CGRectMake(300, 200, 0, 0)));
  XCTAssertEqual(result.radius, 0);
}

- (void)testRejectsNonFiniteGeometryAtomically {
  SmoothNormalizedClipGeometry result = {
      .rect = CGRectMake(1, 2, 3, 4),
      .radius = 5,
  };

  XCTAssertFalse(SmoothClipNormalizeGeometry(
      0, 0, NAN, 20, 4, CGSizeMake(300, 200), &result));
  XCTAssertTrue(CGRectEqualToRect(result.rect, CGRectMake(1, 2, 3, 4)));
  XCTAssertEqual(result.radius, 5);
}

- (void)testV2NormalizesFourRadiiWithOneCSSOverlapFactor {
  SmoothNormalizedClipGeometry result;

  XCTAssertTrue(SmoothClipNormalizeGeometryV2(
      0,
      0,
      100,
      60,
      80,
      40,
      20,
      40,
      SmoothClipCornerCurveContinuous,
      CGSizeMake(100, 60),
      &result));

  // The vertical left edge is limiting: 60 / (80 + 40) == 0.5. All four
  // corners retain their relative proportions instead of clamping separately.
  XCTAssertEqualWithAccuracy(result.radii.topLeft, 40, 1e-9);
  XCTAssertEqualWithAccuracy(result.radii.topRight, 20, 1e-9);
  XCTAssertEqualWithAccuracy(result.radii.bottomRight, 10, 1e-9);
  XCTAssertEqualWithAccuracy(result.radii.bottomLeft, 20, 1e-9);
  XCTAssertEqual(result.radius, 0);
  XCTAssertEqual(result.curve, SmoothClipCornerCurveContinuous);
}

- (void)testV2RejectsAnUnknownCurveWithoutWriting {
  SmoothNormalizedClipGeometry result = {
      .rect = CGRectMake(1, 2, 3, 4),
      .radius = 5,
      .radii = {6, 7, 8, 9},
      .curve = SmoothClipCornerCurveContinuous,
  };

  XCTAssertFalse(SmoothClipNormalizeGeometryV2(
      0, 0, 100, 100, 10, 20, 30, 40, 99, CGSizeMake(100, 100),
      &result));
  XCTAssertTrue(CGRectEqualToRect(result.rect, CGRectMake(1, 2, 3, 4)));
  XCTAssertEqual(result.radii.topLeft, 6);
  XCTAssertEqual(result.curve, SmoothClipCornerCurveContinuous);
}

- (void)testUnequalCornerPathsKeepFixedTopologyAcrossShapesAndCurves {
  const CGRect rect = CGRectMake(10, 20, 100, 80);
  const SmoothClipCornerRadii radii[] = {
      {0, 0, 0, 0},
      {2, 8, 16, 24},
      {40, 5, 10, 20},
  };
  NSUInteger expectedCount = 0;
  for (NSInteger curve = SmoothClipCornerCurveCircular;
       curve <= SmoothClipCornerCurveContinuous;
       curve += 1) {
    for (const SmoothClipCornerRadii &corners : radii) {
      CGPathRef path = SmoothClipCreateRoundedRectPath(
          rect, corners, (SmoothClipCornerCurve)curve);
      NSUInteger count = 0;
      CGPathApply(path, &count, CountPathElements);
      CGPathRelease(path);
      if (expectedCount == 0) expectedCount = count;
      XCTAssertEqual(count, expectedCount);
    }
  }
  // Move + four lines + four cubic corners + close.
  XCTAssertEqual(expectedCount, 10u);
}

@end
