import { describe, expect, it, jest } from '@jest/globals';

jest.mock('react-native-smooth-clip-view', () => {
  const geometry = jest.requireActual<typeof import('../../../src/geometry')>(
    '../../../src/geometry'
  );
  return { normalizeClipPresentation: geometry.normalizeClipPresentation };
});

import {
  calculateOverlayClipGeometry,
  normalizeOverlayPresentation,
  resolveDragClipRadius,
  resolveDragContentScale,
} from '../overlayClipGeometry';

const SCREEN_WIDTH = 390;
const SCREEN_HEIGHT = 844;
const ORIGIN = { x: 20, y: 300, w: 350, h: 100 };
const SOURCE_RADIUS = 20;

function geometryAt(overrides: {
  progress: number;
  translateX?: number;
  translateY?: number;
}) {
  return calculateOverlayClipGeometry({
    progress: overrides.progress,
    originX: ORIGIN.x,
    originY: ORIGIN.y,
    originWidth: ORIGIN.w,
    originHeight: ORIGIN.h,
    screenWidth: SCREEN_WIDTH,
    screenHeight: SCREEN_HEIGHT,
    translateX: overrides.translateX ?? 0,
    translateY: overrides.translateY ?? 0,
    dragThreshold: SCREEN_HEIGHT * 0.8,
    minimumWidth: 200,
    minimumHeight: 200,
    topClipRatio: 0.25,
    dragTranslateY: 400,
    sourceRadius: SOURCE_RADIUS,
  });
}

describe('overlay clip geometry', () => {
  it('reproduces the source card rect at rest', () => {
    const { clip, contentScale } = geometryAt({ progress: 0 });

    expect(clip.x).toBeCloseTo(ORIGIN.x);
    expect(clip.y).toBeCloseTo(ORIGIN.y);
    expect(clip.width).toBeCloseTo(ORIGIN.w);
    expect(clip.height).toBeCloseTo(ORIGIN.h);
    expect(clip.radius).toBeCloseTo(SOURCE_RADIUS);
    expect(contentScale).toBe(1);
  });

  it('fills the screen at full progress', () => {
    const { clip, contentTranslateX, contentTranslateY } = geometryAt({
      progress: 1,
    });

    expect(clip.x).toBeCloseTo(0);
    expect(clip.y).toBeCloseTo(0);
    expect(clip.width).toBeCloseTo(SCREEN_WIDTH);
    expect(clip.height).toBeCloseTo(SCREEN_HEIGHT);
    expect(contentTranslateX).toBeCloseTo(0);
    expect(contentTranslateY).toBeCloseTo(0);
  });

  it('supports a square-cornered drag presentation', () => {
    const geometry = calculateOverlayClipGeometry({
      progress: 1,
      originX: ORIGIN.x,
      originY: ORIGIN.y,
      originWidth: ORIGIN.w,
      originHeight: ORIGIN.h,
      screenWidth: SCREEN_WIDTH,
      screenHeight: SCREEN_HEIGHT,
      translateX: 0,
      translateY: SCREEN_HEIGHT,
      dragThreshold: SCREEN_HEIGHT * 0.8,
      minimumWidth: 200,
      minimumHeight: 200,
      topClipRatio: 0.25,
      dragTranslateY: 400,
      sourceRadius: 0,
      maximumDragRadius: 0,
    });

    expect(geometry.clip.radius).toBe(0);
  });

  it('pins the content translation to the clip origin while undragged', () => {
    const { clip, contentTranslateX, contentTranslateY } = geometryAt({
      progress: 0.5,
    });

    // Both re-anchoring terms vanish at scale 1, so every non-drag state has
    // the content translated by exactly the clip origin.
    expect(contentTranslateX).toBeCloseTo(clip.x);
    expect(contentTranslateY).toBeCloseTo(clip.y);
  });

  it('shrinks the window toward the minimum size as the drag deepens', () => {
    const shallow = geometryAt({ progress: 1, translateY: 100 });
    const deep = geometryAt({ progress: 1, translateY: SCREEN_HEIGHT * 0.8 });

    expect(shallow.clip.width).toBeLessThan(SCREEN_WIDTH);
    expect(shallow.clip.width).toBeGreaterThan(200);
    expect(deep.clip.width).toBeCloseTo(200);
    expect(deep.clip.height).toBeCloseTo(200);
  });

  it('keeps the shrinking window horizontally centred', () => {
    const { clip } = geometryAt({ progress: 1, translateY: 300 });

    expect(clip.x).toBeCloseTo((SCREEN_WIDTH - clip.width) / 2);
  });

  it('carries the horizontal drag straight into the clip and content', () => {
    const { clip, contentTranslateX } = geometryAt({
      progress: 1,
      translateX: 40,
    });

    expect(clip.x).toBeCloseTo(40);
    expect(contentTranslateX).toBeCloseTo(40);
  });

  for (const [edge, translateX] of [
    ['left', -100],
    ['right', 100],
  ] as const) {
    it(`keeps an off-screen ${edge} release intact inside the wider host`, () => {
      const requested = geometryAt({
        progress: 1,
        translateX,
        translateY: 300,
      });
      const normalized = normalizeOverlayPresentation(
        requested,
        SCREEN_WIDTH,
        SCREEN_HEIGHT
      );

      expect(normalized).not.toBeNull();
      expect(normalized!.clip.x).toBeGreaterThanOrEqual(0);
      expect(normalized!.clip.y).toBeGreaterThanOrEqual(0);
      expect(normalized!.clip.x + normalized!.clip.width).toBeLessThanOrEqual(
        SCREEN_WIDTH * 3
      );
      expect(normalized!.clip.y + normalized!.clip.height).toBeLessThanOrEqual(
        SCREEN_HEIGHT
      );
      expect(normalized!.clip.x).toBeCloseTo(requested.clip.x + SCREEN_WIDTH);
      expect(normalized!.clip.width).toBeCloseTo(requested.clip.width);
      expect(normalized!.clip.radius).toBeCloseTo(requested.clip.radius);
      if (edge === 'left') {
        expect(normalized!.clip.x).toBeLessThan(SCREEN_WIDTH);
      } else {
        expect(normalized!.clip.x + normalized!.clip.width).toBeGreaterThan(
          SCREEN_WIDTH * 2
        );
      }
      expect(normalized!.contentTranslateX).toBe(requested.contentTranslateX);
      expect(normalized!.contentTranslateY).toBe(requested.contentTranslateY);
      expect(normalized!.contentScale).toBe(requested.contentScale);
      expect(normalized!.contentVisibleHeight).toBe(
        requested.contentVisibleHeight
      );
    });
  }

  it('ignores upward drag', () => {
    expect(geometryAt({ progress: 1, translateY: -200 })).toEqual(
      geometryAt({ progress: 1, translateY: 0 })
    );
  });

  it('clamps progress outside the unit range', () => {
    expect(geometryAt({ progress: -1 })).toEqual(geometryAt({ progress: 0 }));
    expect(geometryAt({ progress: 2 })).toEqual(geometryAt({ progress: 1 }));
  });
});

describe('drag ramps', () => {
  it('eases the content zoom out toward its floor', () => {
    expect(resolveDragContentScale(0)).toBe(1);
    expect(resolveDragContentScale(1)).toBeCloseTo(0.7);
    // Squaring an even ramp gives up most of the scale early.
    expect(resolveDragContentScale(0.5)).toBeLessThan(0.85);
  });

  it('clamps the content zoom outside the unit range', () => {
    expect(resolveDragContentScale(-1)).toBe(1);
    expect(resolveDragContentScale(5)).toBeCloseTo(0.7);
  });

  it('saturates the corner radius at the end of its ramp', () => {
    expect(resolveDragClipRadius(0, SOURCE_RADIUS)).toBeCloseTo(SOURCE_RADIUS);
    expect(resolveDragClipRadius(0.875, SOURCE_RADIUS)).toBeCloseTo(40);
    expect(resolveDragClipRadius(1, SOURCE_RADIUS)).toBeCloseTo(40);
  });
});
