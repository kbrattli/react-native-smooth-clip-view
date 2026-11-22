import type { SmoothClipPresentation } from 'react-native-smooth-clip-view';
import type { HeroRect } from '../heroBench/heroBenchGeometry';

/**
 * The gallery mount-time bench (docs/gallery-mount-time.md): one photo grid,
 * opened to a detail route by five transition implementations. Every variant
 * lays its tiles and its detail photo out at these window rects, so the
 * recordings of all of them can be analysed with one layout.
 */
export type GalleryLayout = Readonly<{
  /** The twelve tiles, in photo order. */
  tiles: readonly HeroRect[];
  /** The landed photo on the detail route. */
  detail: HeroRect;
  /** Top of the control bar; video analysis ignores everything below it. */
  controlsTop: number;
}>;

export const GALLERY_COLUMNS = 3;
export const GALLERY_ROWS = 4;
export const GALLERY_TILE_COUNT = GALLERY_COLUMNS * GALLERY_ROWS;
/** Every measured opening starts from this tile (row 2, column 2). */
export const GALLERY_MEASURED_TILE = 4;
export const GALLERY_BACKGROUND = '#07111F';
/**
 * Every gallery photo's corner radius, on the tiles and the detail alike, so
 * no variant animates a radius: each keeps 20 pt from tile to detail.
 */
export const GALLERY_RADIUS = 20;

/** A photo's rounded clip at the gallery radius. */
export const galleryRounded = {
  borderRadius: GALLERY_RADIUS,
  overflow: 'hidden' as const,
};

const MARGIN = 12;
const GAP = 6;
const GRID_TOP_INSET = 16;

/**
 * The grid sits below the safe-area top; the detail photo spans the window
 * width at the safe-area top, 4:5 like the hero bench's detail. On the
 * iPhone 18 Pro simulator (402 x 874 pt, safe top 62) a tile is 122 pt and the
 * measured tile is (140, 206, 122, 122), inside the detail (0, 62, 402, 503).
 */
export function galleryLayout(
  windowWidth: number,
  windowHeight: number,
  safeTop: number
): GalleryLayout {
  const size = (windowWidth - MARGIN * 2 - GAP * (GALLERY_COLUMNS - 1)) / 3;
  const gridTop = safeTop + GRID_TOP_INSET;
  const tiles: HeroRect[] = [];
  for (let index = 0; index < GALLERY_TILE_COUNT; index++) {
    const column = index % GALLERY_COLUMNS;
    const row = Math.floor(index / GALLERY_COLUMNS);
    tiles.push({
      x: MARGIN + column * (size + GAP),
      y: gridTop + row * (size + GAP),
      width: size,
      height: size,
    });
  }
  const detail = {
    x: 0,
    y: safeTop,
    width: windowWidth,
    height: Math.round(windowWidth * 1.25),
  };
  const gridBottom = gridTop + GALLERY_ROWS * size + (GALLERY_ROWS - 1) * GAP;
  const controlsTop = Math.min(
    windowHeight,
    Math.max(detail.y + detail.height, gridBottom) + 16
  );
  return { tiles, detail, controlsTop };
}

/**
 * A photo laid out at the detail rect's size, at the origin of a clip with
 * `rect`'s size, and scaled with a transform to cover that clip (centred, as
 * expo-image's `cover` would fit it). The photo never changes size: only
 * this transform does, so expo-image never re-fits it and a teleport host
 * inside it never resizes.
 */
export function galleryPhotoFrame(rect: HeroRect, detail: HeroRect) {
  'worklet';
  const scale = Math.max(
    rect.width / detail.width,
    rect.height / detail.height
  );
  return {
    height: detail.height,
    left: 0,
    position: 'absolute' as const,
    top: 0,
    transform: [
      { translateX: (rect.width - detail.width) / 2 },
      { translateY: (rect.height - detail.height) / 2 },
      { scale },
    ],
    width: detail.width,
  };
}

export function rectStyle(rect: HeroRect) {
  return {
    height: rect.height,
    left: rect.x,
    position: 'absolute' as const,
    top: rect.y,
    width: rect.width,
  };
}

/**
 * Publishes the layout for scripts/hero-bench/record.sh, in the hero bench's
 * shape: `card` is the measured tile and `mask` the other tiles (the analysis
 * ignores their pixels, so only the measured photo is tracked).
 */
export function publishGalleryLayout(
  layout: GalleryLayout,
  windowWidth: number,
  windowHeight: number
) {
  globalThis.__heroBenchLayout = {
    card: layout.tiles[GALLERY_MEASURED_TILE]!,
    detail: layout.detail,
    controlsTop: layout.controlsTop,
    windowWidth,
    windowHeight,
    mask: layout.tiles.filter((_, index) => index !== GALLERY_MEASURED_TILE),
  };
}

/**
 * A flight host is window-sized at the window origin (as in the hero bench),
 * with its photo laid out at the detail rect. This presentation shows that
 * photo cover-cropped into `tile`: the content scale is centred on the host
 * (`p' = c + s(p - c) + t`), so the translation moves the scaled detail centre
 * onto the tile centre.
 *
 * The gallery photos are 3:4 or narrower in portrait, 16:9 in landscape, so
 * the square tile and the 4:5 detail cover-crop each photo along the same
 * axis and the first frame is the tile's own crop.
 */
export function galleryTilePresentation(
  tile: HeroRect,
  detail: HeroRect,
  windowWidth: number,
  windowHeight: number
): SmoothClipPresentation {
  'worklet';
  const scale = Math.max(
    tile.width / detail.width,
    tile.height / detail.height
  );
  const hostCenterX = windowWidth / 2;
  const hostCenterY = windowHeight / 2;
  const detailCenterX = detail.x + detail.width / 2;
  const detailCenterY = detail.y + detail.height / 2;
  const tileCenterX = tile.x + tile.width / 2;
  const tileCenterY = tile.y + tile.height / 2;
  return {
    clip: { ...tile, radius: GALLERY_RADIUS },
    contentTranslateX:
      tileCenterX - hostCenterX - scale * (detailCenterX - hostCenterX),
    contentTranslateY:
      tileCenterY - hostCenterY - scale * (detailCenterY - hostCenterY),
    contentScale: scale,
  };
}

export function galleryDetailPresentation(
  detail: HeroRect
): SmoothClipPresentation {
  'worklet';
  return {
    clip: { ...detail, radius: GALLERY_RADIUS },
    contentTranslateX: 0,
    contentTranslateY: 0,
    contentScale: 1,
  };
}
