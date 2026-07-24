import { describe, expect, it } from '@jest/globals';

import {
  clipGeometryEquals,
  isFiniteClipGeometry,
  normalizeClipGeometry,
} from '../geometry';
import { createWebClipPath } from '../webClipPath';

const bounds = { width: 300, height: 200 };

describe('normalizeClipGeometry', () => {
  it('keeps valid geometry and caps the radius', () => {
    expect(
      normalizeClipGeometry(
        { x: 10, y: 20, width: 100, height: 40, radius: 99 },
        bounds
      )
    ).toEqual({ x: 10, y: 20, width: 100, height: 40, radius: 20 });
  });

  it('intersects negative offsets with host bounds', () => {
    expect(
      normalizeClipGeometry(
        { x: -20, y: -10, width: 70, height: 50, radius: 12 },
        bounds
      )
    ).toEqual({ x: 0, y: 0, width: 50, height: 40, radius: 12 });
  });

  it('intersects geometry that extends beyond the far edges', () => {
    expect(
      normalizeClipGeometry(
        { x: 280, y: 180, width: 80, height: 80, radius: 30 },
        bounds
      )
    ).toEqual({ x: 280, y: 180, width: 20, height: 20, radius: 10 });
  });

  it('turns negative dimensions and radius into an empty clip', () => {
    expect(
      normalizeClipGeometry(
        { x: 50, y: 50, width: -10, height: -20, radius: -4 },
        bounds
      )
    ).toEqual({ x: 50, y: 50, width: 0, height: 0, radius: 0 });
  });

  it('returns an empty edge clip when the rectangle is outside', () => {
    expect(
      normalizeClipGeometry(
        { x: 400, y: 300, width: 20, height: 20, radius: 8 },
        bounds
      )
    ).toEqual({ x: 300, y: 200, width: 0, height: 0, radius: 0 });
  });

  it('rejects every non-finite input atomically', () => {
    expect(
      normalizeClipGeometry(
        {
          x: 0,
          y: 0,
          width: Number.NaN,
          height: 20,
          radius: 4,
        },
        bounds
      )
    ).toBeNull();
    expect(
      normalizeClipGeometry(
        { x: 0, y: 0, width: 20, height: 20, radius: 4 },
        { width: Number.POSITIVE_INFINITY, height: 200 }
      )
    ).toBeNull();
  });

  it('compares geometry without allocating normalized copies', () => {
    const clip = { x: 1, y: 2, width: 3, height: 4, radius: 2 };

    expect(isFiniteClipGeometry(clip)).toBe(true);
    expect(clipGeometryEquals({ ...clip }, clip)).toBe(true);
    expect(clipGeometryEquals(null, clip)).toBe(false);
    expect(isFiniteClipGeometry({ ...clip, radius: Number.NaN })).toBe(false);
  });

  it('creates a web clip-path without changing host layout properties', () => {
    const clipPath = createWebClipPath({
      x: 20,
      y: 10,
      width: 100,
      height: 40,
      radius: 99,
    });

    expect(clipPath).toBe(
      'inset(10px max(0px, calc(100% - 120px)) max(0px, calc(100% - 50px)) 20px round 20px)'
    );
    expect(clipPath).not.toContain('width');
    expect(clipPath).not.toContain('height');
  });
});
