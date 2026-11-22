#import <XCTest/XCTest.h>

#include "SmoothClipFlightGeometry.h"

#include <cmath>

// Pins cpp/SmoothClipFlightGeometry.h: window-space presentations and
// `velocity: 'inherit'` for controller and group springs. Android executes the
// same header, so these tests cover both platforms' math.

using smoothclip::HostWindowTransform;
using smoothclip::Presentation;

namespace {

Presentation makePresentation(
    double x,
    double y,
    double width,
    double height,
    double radius,
    double translateX,
    double translateY,
    double scale) {
  return Presentation{{x, y, width, height, radius}, translateX, translateY, scale};
}

// Where the host draws content point (px, py), in window coordinates, through
// `transform` (identity transform: as if the host sat at the window origin).
CGPoint drawnContentPoint(
    const Presentation &presentation,
    const HostWindowTransform &transform,
    double hostWidth,
    double hostHeight,
    double px,
    double py) {
  const double cx = hostWidth / 2;
  const double cy = hostHeight / 2;
  const double hostX =
      cx + presentation.contentScale * (px - cx) + presentation.contentTranslateX;
  const double hostY =
      cy + presentation.contentScale * (py - cy) + presentation.contentTranslateY;
  return CGPointMake(
      transform.scale * hostX + transform.translateX,
      transform.scale * hostY + transform.translateY);
}

CGRect drawnClip(const Presentation &presentation, const HostWindowTransform &transform) {
  return CGRectMake(
      transform.scale * presentation.clip.x + transform.translateX,
      transform.scale * presentation.clip.y + transform.translateY,
      transform.scale * presentation.clip.width,
      transform.scale * presentation.clip.height);
}

} // namespace

@interface SmoothClipFlightGeometryTests : XCTestCase
@end

@implementation SmoothClipFlightGeometryTests

#pragma mark - Host to window transform

- (void)testAcceptsUniformScaleAndTranslation {
  HostWindowTransform transform;
  XCTAssertTrue(smoothclip::hostWindowTransformFromAffine(
      0.9, 0, 0, 0.9, 20, 115, transform));
  XCTAssertEqualWithAccuracy(transform.scale, 0.9, 1e-12);
  XCTAssertEqualWithAccuracy(transform.translateX, 20, 1e-12);
  XCTAssertEqualWithAccuracy(transform.translateY, 115, 1e-12);
}

- (void)testRejectsWhatAPresentationCannotAbsorb {
  HostWindowTransform transform;
  const double angle = 0.2;
  XCTAssertFalse(smoothclip::hostWindowTransformFromAffine(
      std::cos(angle), std::sin(angle), -std::sin(angle), std::cos(angle), 0, 0,
      transform));
  XCTAssertFalse(smoothclip::hostWindowTransformFromAffine(
      1, 0, 0, 0.5, 0, 0, transform));
  XCTAssertFalse(smoothclip::hostWindowTransformFromAffine(
      1, 0, 0.3, 1, 0, 0, transform));
  XCTAssertFalse(smoothclip::hostWindowTransformFromAffine(
      0, 0, 0, 0, 0, 0, transform));
  XCTAssertFalse(smoothclip::hostWindowTransformFromAffine(
      NAN, 0, 0, 1, 0, 0, transform));
}

#pragma mark - Window space

- (void)testIdentityLeavesThePresentationUnchanged {
  const Presentation window = makePresentation(10, 20, 100, 80, 12, -5, 7, 1.5);
  const Presentation host = smoothclip::presentationFromWindowSpace(
      window, HostWindowTransform{}, 200, 300);
  XCTAssertEqualWithAccuracy(host.clip.x, 10, 1e-9);
  XCTAssertEqualWithAccuracy(host.clip.y, 20, 1e-9);
  XCTAssertEqualWithAccuracy(host.clip.width, 100, 1e-9);
  XCTAssertEqualWithAccuracy(host.clip.radius, 12, 1e-9);
  XCTAssertEqualWithAccuracy(host.contentTranslateX, -5, 1e-9);
  XCTAssertEqualWithAccuracy(host.contentTranslateY, 7, 1e-9);
  XCTAssertEqualWithAccuracy(host.contentScale, 1.5, 1e-9);
}

- (void)testTranslationMatchesTheGalleryTileArithmetic {
  // galleryTileFlightTarget: a tile at window (134, 116) flown to a
  // full-screen frame subtracts the tile origin from the clip and from the
  // content translation. The window-space form passes the frame unchanged.
  const HostWindowTransform transform{1, 134, 116};
  const Presentation window = makePresentation(0, 62, 402, 536, 0, 0, 62, 1);
  const Presentation host =
      smoothclip::presentationFromWindowSpace(window, transform, 134, 134);
  XCTAssertEqualWithAccuracy(host.clip.x, -134, 1e-9);
  XCTAssertEqualWithAccuracy(host.clip.y, 62 - 116, 1e-9);
  XCTAssertEqualWithAccuracy(host.contentTranslateX, -134, 1e-9);
  XCTAssertEqualWithAccuracy(host.contentTranslateY, 62 - 116, 1e-9);
  XCTAssertEqualWithAccuracy(host.contentScale, 1, 1e-9);
}

- (void)testScaledHostDrawsExactlyTheWindowFrame {
  // A host under a 0.9-scaled container (a press-scale, a page sheet's
  // presenter): the converted presentation, drawn through the transform,
  // shows the requested window frame and the requested content mapping.
  const HostWindowTransform transform{0.9, 20.1, 87.4};
  const double hostWidth = 402;
  const double hostHeight = 874;
  Presentation window = makePresentation(0, 62, 402, 503, 0, 0, 0, 1.25);
  window.shadow.offsetY = 9;
  window.shadow.blurRadius = 18;
  window.backdropTranslateX = 30;
  const Presentation host = smoothclip::presentationFromWindowSpace(
      window, transform, hostWidth, hostHeight);

  const CGRect clip = drawnClip(host, transform);
  XCTAssertEqualWithAccuracy(clip.origin.x, 0, 1e-9);
  XCTAssertEqualWithAccuracy(clip.origin.y, 62, 1e-9);
  XCTAssertEqualWithAccuracy(clip.size.width, 402, 1e-9);
  XCTAssertEqualWithAccuracy(clip.size.height, 503, 1e-9);
  for (const CGPoint p : {CGPointMake(0, 0), CGPointMake(201, 437), CGPointMake(-40, 900)}) {
    const CGPoint drawn = drawnContentPoint(host, transform, hostWidth, hostHeight, p.x, p.y);
    const CGPoint wanted =
        drawnContentPoint(window, HostWindowTransform{}, hostWidth, hostHeight, p.x, p.y);
    XCTAssertEqualWithAccuracy(drawn.x, wanted.x, 1e-9);
    XCTAssertEqualWithAccuracy(drawn.y, wanted.y, 1e-9);
  }
  XCTAssertEqualWithAccuracy(host.shadow.offsetY * transform.scale, 9, 1e-9);
  XCTAssertEqualWithAccuracy(host.shadow.blurRadius * transform.scale, 18, 1e-9);
  XCTAssertEqualWithAccuracy(host.backdropTranslateX * transform.scale, 30, 1e-9);
}

- (void)testExplicitCornerRadiiScaleAndUnsetOnesStayUnset {
  Presentation window = makePresentation(0, 0, 100, 100, 10, 0, 0, 1);
  window.clip.topLeftRadius = 20;
  const Presentation host = smoothclip::presentationFromWindowSpace(
      window, HostWindowTransform{0.5, 0, 0}, 100, 100);
  XCTAssertEqualWithAccuracy(host.clip.radius, 20, 1e-9);
  XCTAssertEqualWithAccuracy(host.clip.topLeftRadius, 40, 1e-9);
  XCTAssertTrue(std::isnan(host.clip.topRightRadius));
}

#pragma mark - Inherited velocity

- (void)testLinearTimingHalfwayInheritsTwoPerSecondTowardItsOwnTarget {
  // A linear 1 s run from A to B, replaced halfway by a run to B: it moves
  // (B - A) per second with (B - A) / 2 left, so it covers the remaining
  // distance twice per second.
  const Presentation a = makePresentation(0, 0, 100, 100, 0, 0, 0, 1);
  const Presentation b = makePresentation(100, 50, 300, 200, 0, 40, 20, 1);
  const smoothclip::TimingAnimation linear{1000, 0, 0, 1, 1, 0};
  const smoothclip::RunProgress run = smoothclip::timingRunProgress(linear, 0.5);
  XCTAssertEqualWithAccuracy(run.progress, 0.5, 1e-3);
  XCTAssertEqualWithAccuracy(run.velocity, 1, 1e-3);
  XCTAssertEqualWithAccuracy(
      smoothclip::inheritedRunVelocity(a, b, run, b), 2, 1e-2);
}

- (void)testRetargetSidewaysKeepsOnlyTheProjectedMotion {
  // Moving right, retargeted straight down from where it is: no shared
  // component, so nothing to inherit.
  const Presentation a = makePresentation(0, 0, 100, 100, 0, 0, 0, 1);
  const Presentation b = makePresentation(200, 0, 100, 100, 0, 0, 0, 1);
  const smoothclip::TimingAnimation linear{1000, 0, 0, 1, 1, 0};
  const smoothclip::RunProgress run = smoothclip::timingRunProgress(linear, 0.5);
  const Presentation down = makePresentation(100, 300, 100, 100, 0, 0, 0, 1);
  XCTAssertEqualWithAccuracy(
      smoothclip::inheritedRunVelocity(a, b, run, down), 0, 1e-6);
}

- (void)testFinishedTimingRunInheritsNothing {
  const Presentation a = makePresentation(0, 0, 100, 100, 0, 0, 0, 1);
  const Presentation b = makePresentation(100, 0, 100, 100, 0, 0, 0, 1);
  const smoothclip::TimingAnimation easeInOut{500, 0.42, 0, 0.58, 1, 0};
  const smoothclip::RunProgress done = smoothclip::timingRunProgress(easeInOut, 2);
  XCTAssertEqualWithAccuracy(done.progress, 1, 1e-9);
  XCTAssertEqualWithAccuracy(
      smoothclip::inheritedRunVelocity(a, b, done, a), 0, 1e-6);
}

- (void)testSpringInheritsItsCurrentMotion {
  const Presentation a = makePresentation(0, 0, 100, 100, 0, 0, 0, 1);
  const Presentation b = makePresentation(100, 0, 100, 100, 0, 0, 0, 1);
  smoothclip::SpringAnimation spring{4, 900, 120, 0, false, 0, 6e-9};
  const smoothclip::RunProgress start = smoothclip::springRunProgress(spring, 0);
  XCTAssertEqualWithAccuracy(start.velocity, 0, 1e-9);
  const smoothclip::RunProgress moving = smoothclip::springRunProgress(spring, 0.05);
  XCTAssertGreaterThan(moving.progress, 0);
  XCTAssertGreaterThan(moving.velocity, 0);
  // Toward the same target: positive; back toward the start: negative.
  XCTAssertGreaterThan(smoothclip::inheritedRunVelocity(a, b, moving, b), 0);
  XCTAssertLessThan(smoothclip::inheritedRunVelocity(a, b, moving, a), 0);
}

- (void)testInheritFromWhereTheRunIsMatchesInheritedRunVelocity {
  const Presentation a = makePresentation(0, 0, 100, 100, 8, 0, 0, 1);
  const Presentation b = makePresentation(120, 40, 260, 180, 20, 30, 10, 1);
  const Presentation retarget = makePresentation(300, -20, 200, 220, 4, -10, 5, 1);
  const smoothclip::TimingAnimation easeInOut{400, 0.42, 0, 0.58, 1, 0};
  const smoothclip::RunProgress run = smoothclip::timingRunProgress(easeInOut, 0.13);
  const Presentation here = smoothclip::interpolate(a, b, run.progress);
  XCTAssertEqualWithAccuracy(
      smoothclip::inheritedRunVelocityFrom(a, b, run, here, retarget),
      smoothclip::inheritedRunVelocity(a, b, run, retarget), 1e-9);
}

- (void)testInheritProjectsOntoTheNewRunsOwnDisplacement {
  // Moving right at 200 pt/s (a linear 1 s run over 200 pt). A new run from
  // an explicit `from` at x = 50 to x = 450 has 400 pt to cover: 0.5 of it
  // per second keeps the 200 pt/s. Projected from where the run is (x = 100,
  // 350 pt left), the scalar would be 4/7 and the new run would start faster.
  const Presentation a = makePresentation(0, 0, 100, 100, 0, 0, 0, 1);
  const Presentation b = makePresentation(200, 0, 100, 100, 0, 0, 0, 1);
  const smoothclip::TimingAnimation linear{1000, 0, 0, 1, 1, 0};
  const smoothclip::RunProgress run = smoothclip::timingRunProgress(linear, 0.5);
  const Presentation from = makePresentation(50, 0, 100, 100, 0, 0, 0, 1);
  const Presentation target = makePresentation(450, 0, 100, 100, 0, 0, 0, 1);
  XCTAssertEqualWithAccuracy(
      smoothclip::inheritedRunVelocityFrom(a, b, run, from, target), 0.5, 1e-3);
  XCTAssertEqualWithAccuracy(
      smoothclip::inheritedRunVelocity(a, b, run, target), 200.0 / 350.0, 1e-3);
  // A run that has stopped hands over nothing.
  XCTAssertEqualWithAccuracy(
      smoothclip::inheritedRunVelocityFrom(
          a, b, smoothclip::timingRunProgress(linear, 2), from, target),
      0, 1e-12);
}

- (void)testCoreAnimationSpringMatchesTheSharedSpringUpToCriticalDamping {
  for (const double damping : {20.0, 60.0}) {
    // zeta = damping / (2 sqrt(k m)) = damping / 60: under- and critical.
    const smoothclip::SpringAnimation spring{1, 900, damping, 1.5, false, 0, 6e-9};
    for (const double t : {0.0, 0.03, 0.11, 0.4}) {
      const smoothclip::RunProgress shared = smoothclip::springRunProgress(spring, t);
      const smoothclip::RunProgress ca =
          smoothclip::coreAnimationSpringRunProgress(spring, t);
      XCTAssertEqualWithAccuracy(ca.progress, shared.progress, 1e-12);
      XCTAssertEqualWithAccuracy(ca.velocity, shared.velocity, 1e-12);
    }
  }
}

- (void)testCoreAnimationOverdampedSpringIsThePhysicalSolution {
  // zeta = 2: x'' = -k (x - 1) - c x' (unit mass), x(0) = 0, x'(0) = v0.
  const smoothclip::SpringAnimation spring{1, 400, 80, 3, false, 0, 6e-9};
  const smoothclip::RunProgress start =
      smoothclip::coreAnimationSpringRunProgress(spring, 0);
  XCTAssertEqualWithAccuracy(start.progress, 0, 1e-12);
  XCTAssertEqualWithAccuracy(start.velocity, 3, 1e-12);
  constexpr double h = 1e-5;
  for (const double t : {0.02, 0.1, 0.35}) {
    const smoothclip::RunProgress at =
        smoothclip::coreAnimationSpringRunProgress(spring, t);
    const double before =
        smoothclip::coreAnimationSpringRunProgress(spring, t - h).progress;
    const double after =
        smoothclip::coreAnimationSpringRunProgress(spring, t + h).progress;
    // The velocity is the position's derivative...
    XCTAssertEqualWithAccuracy(at.velocity, (after - before) / (2 * h), 1e-5);
    // ...and the position obeys the spring's equation of motion.
    const double acceleration = (after - 2 * at.progress + before) / (h * h);
    XCTAssertEqualWithAccuracy(
        acceleration, -400 * (at.progress - 1) - 80 * at.velocity, 1e-2);
    XCTAssertGreaterThan(at.progress, 0);
    XCTAssertLessThan(at.progress, 1);
  }
}

@end
