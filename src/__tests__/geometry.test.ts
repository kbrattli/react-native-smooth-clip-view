import { describe, expect, it } from '@jest/globals';

import {
  canonicalizeClipGeometry,
  canonicalizeClipPresentation,
  clipPresentationEquals,
  createClipPresentation,
  isFiniteClipPresentation,
  clipGeometryEquals,
  isFiniteClipGeometry,
  normalizeClipGeometry,
  normalizeClipPresentation,
} from '../geometry';
import type { ClipGeometry } from '../geometry';

const bounds = { width: 300, height: 200 };

describe('normalizeClipGeometry', () => {
  it('keeps valid geometry and caps the radius', () => {
    expect(
      normalizeClipGeometry(
        { x: 10, y: 20, width: 100, height: 40, radius: 99 },
        bounds
      )
    ).toEqual({
      x: 10,
      y: 20,
      width: 100,
      height: 40,
      radius: 20,
      topLeftRadius: 20,
      topRightRadius: 20,
      bottomRightRadius: 20,
      bottomLeftRadius: 20,
      curve: 'circular',
    });
  });

  it('intersects negative offsets with host bounds', () => {
    expect(
      normalizeClipGeometry(
        { x: -20, y: -10, width: 70, height: 50, radius: 12 },
        bounds
      )
    ).toEqual({
      x: 0,
      y: 0,
      width: 50,
      height: 40,
      radius: 12,
      topLeftRadius: 12,
      topRightRadius: 12,
      bottomRightRadius: 12,
      bottomLeftRadius: 12,
      curve: 'circular',
    });
  });

  it('intersects geometry that extends beyond the far edges', () => {
    expect(
      normalizeClipGeometry(
        { x: 280, y: 180, width: 80, height: 80, radius: 30 },
        bounds
      )
    ).toEqual({
      x: 280,
      y: 180,
      width: 20,
      height: 20,
      radius: 10,
      topLeftRadius: 10,
      topRightRadius: 10,
      bottomRightRadius: 10,
      bottomLeftRadius: 10,
      curve: 'circular',
    });
  });

  it('turns negative dimensions and radius into an empty clip', () => {
    expect(
      normalizeClipGeometry(
        { x: 50, y: 50, width: -10, height: -20, radius: -4 },
        bounds
      )
    ).toEqual({
      x: 50,
      y: 50,
      width: 0,
      height: 0,
      radius: 0,
      topLeftRadius: 0,
      topRightRadius: 0,
      bottomRightRadius: 0,
      bottomLeftRadius: 0,
      curve: 'circular',
    });
  });

  it('returns an empty edge clip when the rectangle is outside', () => {
    expect(
      normalizeClipGeometry(
        { x: 400, y: 300, width: 20, height: 20, radius: 8 },
        bounds
      )
    ).toEqual({
      x: 300,
      y: 200,
      width: 0,
      height: 0,
      radius: 0,
      topLeftRadius: 0,
      topRightRadius: 0,
      bottomRightRadius: 0,
      bottomLeftRadius: 0,
      curve: 'circular',
    });
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

  it('expands corner and curve defaults into canonical geometry', () => {
    expect(
      canonicalizeClipGeometry({
        x: 1,
        y: 2,
        width: 200,
        height: 100,
        radius: 12,
        topLeftRadius: 24,
        bottomRightRadius: 8,
        curve: 'continuous',
      })
    ).toEqual({
      x: 1,
      y: 2,
      width: 200,
      height: 100,
      radius: 0,
      topLeftRadius: 24,
      topRightRadius: 12,
      bottomRightRadius: 8,
      bottomLeftRadius: 12,
      curve: 'continuous',
    });
  });

  it('uses CSS proportional reduction for overlapping corner pairs', () => {
    expect(
      canonicalizeClipGeometry({
        x: 0,
        y: 0,
        width: 100,
        height: 60,
        radius: 20,
        topLeftRadius: 80,
        topRightRadius: 40,
        bottomRightRadius: 20,
        bottomLeftRadius: 40,
      })
    ).toEqual({
      x: 0,
      y: 0,
      width: 100,
      height: 60,
      radius: 0,
      topLeftRadius: 40,
      topRightRadius: 20,
      bottomRightRadius: 10,
      bottomLeftRadius: 20,
      curve: 'circular',
    });
  });

  it('compares explicit defaults and shorthand geometry as equal', () => {
    const shorthand = { x: 1, y: 2, width: 30, height: 40, radius: 5 };

    expect(
      clipGeometryEquals(
        {
          ...shorthand,
          topLeftRadius: 5,
          topRightRadius: 5,
          bottomRightRadius: 5,
          bottomLeftRadius: 5,
          curve: 'circular',
        },
        shorthand
      )
    ).toBe(true);
    expect(
      clipGeometryEquals({ ...shorthand, curve: 'continuous' }, shorthand)
    ).toBe(false);
  });

  it('rejects invalid optional corner and curve values atomically', () => {
    const clip = { x: 1, y: 2, width: 30, height: 40, radius: 5 };

    expect(isFiniteClipGeometry({ ...clip, topLeftRadius: Number.NaN })).toBe(
      false
    );
    expect(
      isFiniteClipGeometry({
        ...clip,
        curve: 'invalid' as ClipGeometry['curve'],
      })
    ).toBe(false);
    expect(
      normalizeClipGeometry(
        { ...clip, bottomLeftRadius: Number.POSITIVE_INFINITY },
        bounds
      )
    ).toBeNull();
  });
});

describe('SmoothClipPresentation', () => {
  it('keeps the geometry-only constructor call and defaults content scale to one', () => {
    const clip = { x: 1, y: 2, width: 30, height: 40, radius: 5 };
    const presentation = createClipPresentation(clip, -11, 17);

    expect(presentation).toEqual({
      clip: {
        ...clip,
        topLeftRadius: 5,
        topRightRadius: 5,
        bottomRightRadius: 5,
        bottomLeftRadius: 5,
        curve: 'circular',
      },
      contentTranslateX: -11,
      contentTranslateY: 17,
      contentScale: 1,
    });
    expect(isFiniteClipPresentation(presentation)).toBe(true);
    expect(
      clipPresentationEquals(
        { clip: { ...clip }, contentTranslateX: -11, contentTranslateY: 17 },
        presentation
      )
    ).toBe(true);
    expect(
      isFiniteClipPresentation({
        ...presentation,
        contentTranslateY: Number.NaN,
      })
    ).toBe(false);
  });

  it('validates content scale as finite and positive', () => {
    const clip = { x: 1, y: 2, width: 30, height: 40, radius: 5 };

    expect(
      isFiniteClipPresentation(createClipPresentation(clip, 0, 0, 2))
    ).toBe(true);
    expect(
      isFiniteClipPresentation(createClipPresentation(clip, 0, 0, 0))
    ).toBe(false);
    expect(
      isFiniteClipPresentation(
        createClipPresentation(clip, 0, 0, Number.POSITIVE_INFINITY)
      )
    ).toBe(false);
  });

  it('does not sanitize invalid clip scalars in the canonical constructor', () => {
    expect(
      isFiniteClipPresentation(
        createClipPresentation({
          x: 0,
          y: 0,
          width: 20,
          height: 20,
          radius: Number.NaN,
          topLeftRadius: 4,
          topRightRadius: 4,
          bottomRightRadius: 4,
          bottomLeftRadius: 4,
        })
      )
    ).toBe(false);
    expect(
      isFiniteClipPresentation(
        createClipPresentation({
          x: 0,
          y: 0,
          width: Number.NEGATIVE_INFINITY,
          height: 20,
          radius: 4,
        })
      )
    ).toBe(false);
  });

  it('canonicalizes and host-normalizes a complete presentation', () => {
    const presentation = createClipPresentation(
      {
        x: -20,
        y: -10,
        width: 70,
        height: 50,
        radius: 12,
        topLeftRadius: 20,
        curve: 'continuous',
      },
      -11,
      17,
      1.5
    );

    expect(canonicalizeClipPresentation(presentation)).toEqual({
      clip: {
        x: -20,
        y: -10,
        width: 70,
        height: 50,
        radius: 0,
        topLeftRadius: 20,
        topRightRadius: 12,
        bottomRightRadius: 12,
        bottomLeftRadius: 12,
        curve: 'continuous',
      },
      contentTranslateX: -11,
      contentTranslateY: 17,
      contentScale: 1.5,
    });
    expect(normalizeClipPresentation(presentation, bounds)).toEqual({
      clip: {
        x: 0,
        y: 0,
        width: 50,
        height: 40,
        radius: 0,
        topLeftRadius: 20,
        topRightRadius: 12,
        bottomRightRadius: 12,
        bottomLeftRadius: 12,
        curve: 'continuous',
      },
      contentTranslateX: -11,
      contentTranslateY: 17,
      contentScale: 1.5,
    });
  });

  it('canonicalizes boxShadow defaults, clamps bounded values, and is idempotent', () => {
    const presentation = {
      clip: { x: 0, y: 0, width: 40, height: 30, radius: 8 },
      contentTranslateX: 0,
      contentTranslateY: 0,
      boxShadow: {
        color: '#33669980',
        blurRadius: -5,
        spreadDistance: -3,
        offsetX: -4,
        offsetY: 7,
      },
    } as const;
    const canonical = canonicalizeClipPresentation(presentation);

    expect(canonical?.boxShadow).toEqual({
      color: 0x33669980,
      offsetX: -4,
      offsetY: 7,
      blurRadius: 0,
      spreadDistance: -3,
    });
    expect(canonicalizeClipPresentation(canonical!)).toEqual(canonical);
  });

  it('distinguishes absent shadows and rejects non-finite shadow channels atomically', () => {
    const base = createClipPresentation({
      x: 0,
      y: 0,
      width: 40,
      height: 30,
      radius: 8,
    });
    expect(base.boxShadow).toBeUndefined();
    expect(
      canonicalizeClipPresentation({
        ...base,
        boxShadow: { offsetX: 0, offsetY: 0, blurRadius: Number.NaN },
      })
    ).toBeNull();
    expect(
      clipPresentationEquals(base, {
        ...base,
        boxShadow: { offsetX: 0, offsetY: 0 },
      })
    ).toBe(false);
    expect(
      canonicalizeClipPresentation(
        createClipPresentation(base.clip, 0, 0, 1, {
          offsetX: 0,
          offsetY: Number.POSITIVE_INFINITY,
        })
      )
    ).toBeNull();
  });
});
