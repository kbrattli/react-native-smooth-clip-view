import { describe, expect, it } from '@jest/globals';
import {
  getStressClipGeometry,
  STRESS_EXPANDED_CLIP_RADIUS,
} from '../stressGeometry';

describe('stress-test clip geometry', () => {
  it('uses the same deterministic collapsed geometry for every host', () => {
    const geometry = getStressClipGeometry(0, 200, 240);

    expect(geometry.x).toBeCloseTo(38);
    expect(geometry.y).toBeCloseTo(58);
    expect(geometry.width).toBeCloseTo(124);
    expect(geometry.height).toBeCloseTo(124);
    expect(geometry.radius).toBeCloseTo(62);
  });

  it('expands to the full fixed host footprint', () => {
    expect(getStressClipGeometry(1, 200, 240)).toEqual({
      x: 0,
      y: 0,
      width: 200,
      height: 240,
      radius: STRESS_EXPANDED_CLIP_RADIUS,
    });
  });

  it('interpolates corner radius with the same progress value', () => {
    expect(getStressClipGeometry(0.5, 200, 240).radius).toBe(40);
  });

  it('makes the fully collapsed clip a centered circle', () => {
    const geometry = getStressClipGeometry(0, 180, 220);

    expect(geometry.width).toBe(geometry.height);
    expect(geometry.radius).toBe(geometry.width / 2);
    expect(geometry.x).toBe((180 - geometry.width) / 2);
    expect(geometry.y).toBe((220 - geometry.height) / 2);
  });

  it('clamps progress before interpolating geometry', () => {
    expect(getStressClipGeometry(-1, 200, 240)).toEqual(
      getStressClipGeometry(0, 200, 240)
    );
    expect(getStressClipGeometry(2, 200, 240)).toEqual(
      getStressClipGeometry(1, 200, 240)
    );
  });
});
