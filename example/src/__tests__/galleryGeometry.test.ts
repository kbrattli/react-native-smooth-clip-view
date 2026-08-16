import { describe, expect, it } from '@jest/globals';
import {
  interpolateGalleryFrame,
  resolveAspectFitFrame,
  resolveDraggedGalleryFrame,
  resolveGalleryBackdropOpacity,
  resolveGalleryDismissProgress,
  resolveGalleryFrameProgress,
  resolveGalleryPresentation,
} from '../galleryGeometry';

describe('gallery geometry', () => {
  it('fits portrait images to the container height', () => {
    const frame = resolveAspectFitFrame(390, 844, 1180, 1572);

    expect(frame.x).toBe(0);
    expect(frame.y).toBeCloseTo(162.22033898305085);
    expect(frame.width).toBe(390);
    expect(frame.height).toBeCloseTo(519.5593220338983);
  });

  it('fits landscape images to the container width', () => {
    const frame = resolveAspectFitFrame(390, 844, 2096, 1180);

    expect(frame.x).toBe(0);
    expect(frame.y).toBeCloseTo(312.21946564885496);
    expect(frame.width).toBe(390);
    expect(frame.height).toBeCloseTo(219.56106870229007);
  });

  it('centres a square inside a portrait container', () => {
    expect(resolveAspectFitFrame(390, 844, 100, 100)).toEqual({
      x: 0,
      y: 227,
      width: 390,
      height: 390,
    });
  });

  it('keeps extreme aspect ratios inside the container', () => {
    const frame = resolveAspectFitFrame(390, 844, 4000, 100);

    expect(frame.x).toBe(0);
    expect(frame.y).toBeCloseTo(417.125);
    expect(frame.width).toBe(390);
    expect(frame.height).toBeCloseTo(9.75);
  });

  it('falls back to a sanitized full-container frame for invalid images', () => {
    expect(resolveAspectFitFrame(390, 844, 0, Number.NaN)).toEqual({
      x: 0,
      y: 0,
      width: 390,
      height: 844,
    });
    expect(resolveAspectFitFrame(-1, Number.NaN, 0, 0)).toEqual({
      x: 0,
      y: 0,
      width: 0,
      height: 0,
    });
  });

  it('interpolates from an absolute square tile to the destination', () => {
    const source = { x: 20, y: 300, width: 130, height: 130 };
    const destination = { x: 0, y: 200, width: 390, height: 500 };

    expect(interpolateGalleryFrame(source, destination, 0)).toEqual(source);
    expect(interpolateGalleryFrame(source, destination, 0.5)).toEqual({
      x: 10,
      y: 250,
      width: 260,
      height: 315,
    });
    expect(interpolateGalleryFrame(source, destination, 1)).toEqual(
      destination
    );
  });

  it('clamps frame progress', () => {
    const source = { x: 0, y: 0, width: 100, height: 100 };
    const destination = { x: 10, y: 20, width: 300, height: 400 };

    expect(interpolateGalleryFrame(source, destination, -1)).toEqual(
      interpolateGalleryFrame(source, destination, 0)
    );
    expect(interpolateGalleryFrame(source, destination, 2)).toEqual(
      interpolateGalleryFrame(source, destination, 1)
    );
  });

  it('maps portrait square and destination endpoints onto one fixed image', () => {
    const source = { x: 130, y: 80, width: 130, height: 130 };
    const destination = resolveAspectFitFrame(390, 844, 1180, 1572);
    const sourcePresentation = resolveGalleryPresentation(
      source,
      destination,
      390,
      844
    );
    const destinationPresentation = resolveGalleryPresentation(
      destination,
      destination,
      390,
      844
    );

    expect(sourcePresentation.clip).toEqual({ ...source, radius: 0 });
    expect(sourcePresentation.contentScale).toBeCloseTo(130 / 390);
    expect(sourcePresentation.contentTranslateX).toBe(0);
    expect(sourcePresentation.contentTranslateY).toBeCloseTo(-277);
    expect(
      destination.height * sourcePresentation.contentScale
    ).toBeGreaterThan(source.height);
    expect(destinationPresentation).toEqual({
      clip: { ...destination, radius: 0 },
      contentScale: 1,
      contentTranslateX: 0,
      contentTranslateY: 0,
    });
  });

  it('keeps a landscape cover centred behind its square source clip', () => {
    const source = { x: 0, y: 240, width: 130, height: 130 };
    const destination = resolveAspectFitFrame(390, 844, 2096, 1180);
    const presentation = resolveGalleryPresentation(
      source,
      destination,
      390,
      844
    );
    const scaledWidth = destination.width * presentation.contentScale;
    const scaledHeight = destination.height * presentation.contentScale;

    expect(presentation.contentScale).toBeCloseTo(
      source.height / destination.height
    );
    expect(scaledWidth).toBeGreaterThan(source.width);
    expect(scaledHeight).toBeCloseTo(source.height);
    expect(390 / 2 + presentation.contentTranslateX).toBeCloseTo(
      source.x + source.width / 2
    );
    expect(844 / 2 + presentation.contentTranslateY).toBeCloseTo(
      source.y + source.height / 2
    );
    expect(presentation.clip.radius).toBe(0);
  });

  it('recovers opening progress from the visible native frame', () => {
    const source = { x: 20, y: 300, width: 130, height: 130 };
    const destination = { x: 0, y: 200, width: 390, height: 500 };

    expect(resolveGalleryFrameProgress(source, destination, source)).toBe(0);
    expect(
      resolveGalleryFrameProgress(
        source,
        destination,
        interpolateGalleryFrame(source, destination, 0.45)
      )
    ).toBeCloseTo(0.45);
    expect(resolveGalleryFrameProgress(source, destination, destination)).toBe(
      1
    );
  });

  it.each([
    ['portrait', 1180, 1572],
    ['landscape', 2096, 1180],
  ])(
    'keeps %s clip, translation, and child scale on one frame path',
    (_label, imageWidth, imageHeight) => {
      const source = { x: 130, y: 80, width: 130, height: 130 };
      const destination = resolveAspectFitFrame(
        390,
        844,
        imageWidth,
        imageHeight
      );
      const sourcePresentation = resolveGalleryPresentation(
        source,
        destination,
        390,
        844
      );
      const destinationPresentation = resolveGalleryPresentation(
        destination,
        destination,
        390,
        844
      );

      for (const progress of [0.2, 0.5, 0.8]) {
        const frame = interpolateGalleryFrame(source, destination, progress);
        const expected = resolveGalleryPresentation(
          frame,
          destination,
          390,
          844
        );

        expect(expected.contentTranslateX).toBeCloseTo(
          sourcePresentation.contentTranslateX * (1 - progress) +
            destinationPresentation.contentTranslateX * progress
        );
        expect(expected.contentTranslateY).toBeCloseTo(
          sourcePresentation.contentTranslateY * (1 - progress) +
            destinationPresentation.contentTranslateY * progress
        );
        expect(expected.contentScale).toBeCloseTo(
          sourcePresentation.contentScale * (1 - progress) +
            destinationPresentation.contentScale * progress
        );
        expect(expected.clip).toEqual({ ...frame, radius: 0 });
      }
    }
  );

  it('moves and uniformly scales the intact image during dismissal', () => {
    const frame = resolveAspectFitFrame(390, 844, 1180, 1572);
    const dragged = resolveDraggedGalleryFrame(frame, 24, 120, 0.5);
    const presentation = resolveGalleryPresentation(dragged, frame, 390, 844);

    expect(dragged.x).toBeGreaterThan(frame.x + 24);
    expect(dragged.y).toBeGreaterThan(frame.y + 120);
    expect(dragged.width).toBeLessThan(frame.width);
    expect(dragged.height).toBeLessThan(frame.height);
    expect(dragged.width / dragged.height).toBeCloseTo(
      frame.width / frame.height
    );
    expect(presentation.clip).toEqual({ ...dragged, radius: 0 });
    expect(presentation.contentScale).toBeCloseTo(dragged.width / frame.width);
    expect(390 / 2 + presentation.contentTranslateX).toBeCloseTo(
      dragged.x + dragged.width / 2
    );
    expect(844 / 2 + presentation.contentTranslateY).toBeCloseTo(
      dragged.y + dragged.height / 2
    );
  });

  it('interpolates a dragged image onto the newly selected square tile', () => {
    const resting = resolveAspectFitFrame(390, 844, 2096, 1180);
    const release = resolveDraggedGalleryFrame(resting, -12, 180, 0.45);
    const selectedTile = { x: 130, y: 420, width: 130, height: 130 };
    const halfway = interpolateGalleryFrame(release, selectedTile, 0.5);
    const halfwayPresentation = resolveGalleryPresentation(
      halfway,
      resting,
      390,
      844
    );

    expect(interpolateGalleryFrame(release, selectedTile, 0)).toEqual(release);
    expect(interpolateGalleryFrame(release, selectedTile, 1)).toEqual(
      selectedTile
    );
    expect(halfwayPresentation.clip).toEqual({ ...halfway, radius: 0 });
    expect(halfwayPresentation.contentScale).toBeGreaterThan(0);
  });

  it('clamps dismiss progress and fades only the separate backdrop', () => {
    expect(resolveGalleryDismissProgress(-20, 400)).toBe(0);
    expect(resolveGalleryDismissProgress(100, 400)).toBe(0.25);
    expect(resolveGalleryDismissProgress(800, 400)).toBe(1);
    expect(resolveGalleryBackdropOpacity(0.5, 0)).toBe(0.5);
    expect(resolveGalleryBackdropOpacity(1, 0.25)).toBe(0.75);
    expect(resolveGalleryBackdropOpacity(1, 2)).toBe(0);
  });
});
