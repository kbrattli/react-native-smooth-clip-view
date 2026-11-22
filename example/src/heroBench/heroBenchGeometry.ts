import type { SmoothClipPresentation } from 'react-native-smooth-clip-view';

export type HeroRect = Readonly<{
  x: number;
  y: number;
  width: number;
  height: number;
}>;

export type HeroLayout = Readonly<{
  /** The resting card on the list screen. */
  card: HeroRect;
  /** The landed hero on the detail screen. */
  detail: HeroRect;
  /** Top of the control bar; video analysis ignores everything below it. */
  controlsTop: number;
}>;

export const HERO_CARD_RADIUS = 24;
export const HERO_SHARED_TAG = 'hero-bench';
/**
 * Flight tag of the detail hero (a `SmoothClipFlightTarget`): it mounts hidden
 * while the list card flies, and is revealed in the frame the flight lands.
 */
export const HERO_FLIGHT_TAG = 'hero-bench-detail';
export const HERO_BACKGROUND = '#07111F';
/**
 * Painted under every hero image. A frame that shows this colour shows the
 * hero's frame before its pixels decoded — distinct from a frame that shows
 * nothing at all.
 */
export const HERO_PLACEHOLDER = '#FF00FF';
export const HERO_IMAGE = require('../../assets/gallery/coastal-overlook.jpg');

const CARD_INSET = 24;
const CARD_HEIGHT = 200;

/**
 * Where a page sheet's content begins in the window: the sheet's own top
 * edge. A sheet route lays its hero out at its local origin, so this is the
 * hero's window y. Measured on the iPhone 18 Pro simulator (iOS 27), where a
 * page sheet starts at the safe-area top (y = 62) and the presenter is not
 * scaled. The flight needs it before the sheet exists; SET measures its
 * target after the mount.
 */
export function heroSheetTop(safeTop: number): number {
  return safeTop;
}

/**
 * SET and the flight place the hero at the same window coordinates in each
 * scenario, so their source and target frames are identical and a recording
 * can be analysed with one region. `detailTop` is the landed hero's window y:
 * the safe-area top on a pushed screen, the sheet's top edge on a sheet.
 */
export function heroLayout(
  windowWidth: number,
  windowHeight: number,
  safeTop: number,
  detailTop: number = safeTop
): HeroLayout {
  const detailHeight = Math.round(windowWidth * 1.25);
  const detail = {
    x: 0,
    y: detailTop,
    width: windowWidth,
    height: detailHeight,
  };
  const cardY = Math.round(safeTop + detailHeight * 0.45);
  const card = {
    x: CARD_INSET,
    y: cardY,
    width: windowWidth - CARD_INSET * 2,
    height: CARD_HEIGHT,
  };
  const controlsTop = Math.min(
    windowHeight,
    Math.max(safeTop + detailHeight, card.y + card.height) + 16
  );
  return { card, detail, controlsTop };
}

declare global {
  // Read by scripts/hero-bench/record.sh to place the analysis region.
  // The gallery bench adds `mask`: rects whose pixels the analysis ignores.
  var __heroBenchLayout:
    | (HeroLayout & {
        windowWidth: number;
        windowHeight: number;
        mask?: readonly HeroRect[];
      })
    | undefined;
}

export function publishHeroLayout(
  layout: HeroLayout,
  windowWidth: number,
  windowHeight: number
) {
  globalThis.__heroBenchLayout = { ...layout, windowWidth, windowHeight };
}

/**
 * The presentation that shows `detail`'s content cover-cropped into `card`.
 *
 * The host is the full window and its content is laid out at `detail`. The
 * content scale is centred on the host (`p' = c + s(p - c) + t`), so the
 * translation moves the scaled detail centre onto the card centre.
 *
 * The first frame is pixel-identical to the card only when both cover crops
 * are bound by the same axis. The bench photo is portrait (1180 x 1572), so
 * the 354 x 200 card and the 402 x 503 detail both fit its width, and the
 * aperture shows exactly the band the card shows. SET has no such
 * constraint: it re-fits the live image view every frame.
 */
export function heroCardPresentation(
  layout: HeroLayout,
  windowWidth: number,
  windowHeight: number
): SmoothClipPresentation {
  'worklet';
  const { card, detail } = layout;
  const scale = Math.max(
    card.width / detail.width,
    card.height / detail.height
  );
  const hostCenterX = windowWidth / 2;
  const hostCenterY = windowHeight / 2;
  const detailCenterX = detail.x + detail.width / 2;
  const detailCenterY = detail.y + detail.height / 2;
  const cardCenterX = card.x + card.width / 2;
  const cardCenterY = card.y + card.height / 2;
  return {
    clip: {
      x: card.x,
      y: card.y,
      width: card.width,
      height: card.height,
      radius: HERO_CARD_RADIUS,
    },
    contentTranslateX:
      cardCenterX - hostCenterX - scale * (detailCenterX - hostCenterX),
    contentTranslateY:
      cardCenterY - hostCenterY - scale * (detailCenterY - hostCenterY),
    contentScale: scale,
  };
}

export function heroDetailPresentation(
  layout: HeroLayout
): SmoothClipPresentation {
  'worklet';
  const { detail } = layout;
  return {
    clip: {
      x: detail.x,
      y: detail.y,
      width: detail.width,
      height: detail.height,
      radius: 0,
    },
    contentTranslateX: 0,
    contentTranslateY: 0,
    contentScale: 1,
  };
}

/**
 * Reanimated's SET default is `withTiming` with `Easing.inOut(Easing.quad)`.
 * This is the standard cubic-Bezier fit of that curve.
 */
export const HERO_EASE_IN_OUT_QUAD = [0.455, 0.03, 0.515, 0.955] as const;

/**
 * `from` moved towards `to` by `t`, channel by channel, as Core Animation
 * interpolates a run. Both are full presentations of the
 * same host; the result takes `to`'s space.
 */
export function mixHeroPresentation(
  from: SmoothClipPresentation,
  to: SmoothClipPresentation,
  t: number
): SmoothClipPresentation {
  'worklet';
  const mix = (a: number, b: number) => a + (b - a) * t;
  return {
    clip: {
      x: mix(from.clip.x, to.clip.x),
      y: mix(from.clip.y, to.clip.y),
      width: mix(from.clip.width, to.clip.width),
      height: mix(from.clip.height, to.clip.height),
      radius: mix(from.clip.radius, to.clip.radius),
    },
    contentTranslateX: mix(from.contentTranslateX, to.contentTranslateX),
    contentTranslateY: mix(from.contentTranslateY, to.contentTranslateY),
    contentScale: mix(from.contentScale ?? 1, to.contentScale ?? 1),
    space: to.space,
  };
}
