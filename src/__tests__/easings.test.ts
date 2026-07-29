import { describe, expect, it } from '@jest/globals';

import { ClipEasings } from '../easings';

// y-coordinate of the cubic Bézier (0,0)-(x1,y1)-(x2,y2)-(1,1) at parameter t.
function bezierAxis(t: number, a: number, b: number): number {
  const inverse = 1 - t;
  return 3 * inverse * inverse * t * a + 3 * inverse * t * t * b + t * t * t;
}

const SAMPLES = Array.from({ length: 101 }, (_, index) => index / 100);

// With x1 = 1/3 and x2 = 2/3 the Bézier's x(t) is the identity, so y(t) must
// equal the closed-form easing polynomial at every t — exactly, not
// approximately (tolerance covers float rounding only).
function expectIdentityXAndClosedForm(
  controlPoints: readonly [number, number, number, number],
  closedForm: (t: number) => number
) {
  const [x1, y1, x2, y2] = controlPoints;
  for (const t of SAMPLES) {
    expect(bezierAxis(t, x1, x2)).toBeCloseTo(t, 12);
    expect(bezierAxis(t, y1, y2)).toBeCloseTo(closedForm(t), 12);
  }
}

describe('ClipEasings', () => {
  it('easeOutCubic is exactly 1 - (1 - t)^3', () => {
    expectIdentityXAndClosedForm(
      ClipEasings.easeOutCubic,
      (t) => 1 - (1 - t) ** 3
    );
  });

  it('easeInCubic is exactly t^3', () => {
    expectIdentityXAndClosedForm(ClipEasings.easeInCubic, (t) => t ** 3);
  });

  it('easeOutQuad is exactly 1 - (1 - t)^2', () => {
    expectIdentityXAndClosedForm(
      ClipEasings.easeOutQuad,
      (t) => 1 - (1 - t) ** 2
    );
  });

  it('easeInQuad is exactly t^2', () => {
    expectIdentityXAndClosedForm(ClipEasings.easeInQuad, (t) => t ** 2);
  });

  it('linear yields y === x at every parameter', () => {
    const [x1, y1, x2, y2] = ClipEasings.linear;
    for (const t of SAMPLES) {
      // x(t) is not the identity here, but y(t) === x(t) pointwise makes the
      // curve the exact identity function y = x.
      expect(bezierAxis(t, y1, y2)).toBeCloseTo(bezierAxis(t, x1, x2), 12);
    }
  });
});
