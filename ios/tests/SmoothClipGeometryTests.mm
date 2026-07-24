#import <XCTest/XCTest.h>

#import "../SmoothClipGeometry.h"

@interface SmoothClipGeometryTests : XCTestCase
@end

@implementation SmoothClipGeometryTests

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

@end
