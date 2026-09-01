import type {
  ClipBoxShadow,
  ClipGeometry,
} from 'react-native-smooth-clip-view';

export type OverlayClipGeometryInput = Readonly<{
  progress: number;
  originX: number;
  originY: number;
  originWidth: number;
  originHeight: number;
  screenWidth: number;
  screenHeight: number;
  translateX: number;
  translateY: number;
  dragThreshold: number;
  minimumWidth: number;
  minimumHeight: number;
  topClipRatio: number;
  dragTranslateY: number;
  /** Resting corner radius; the drag ramps up from here. */
  sourceRadius: number;
  /** Corner radius reached during a full dismiss drag. Defaults to 40. */
  maximumDragRadius?: number;
}>;

export type OverlayClipGeometryResult = Readonly<{
  clip: ClipGeometry;
  contentTranslateX: number;
  contentTranslateY: number;
  /** Zoom applied to the content by the drag; 1 whenever no drag is held. */
  contentScale: number;
  boxShadow?: ClipBoxShadow;
  /** Reveal height in content space, before the drag's shrink. */
  contentVisibleHeight: number;
}>;

// Content zoom-out while dragging to dismiss. Squaring an even ramp eases the
// shrink OUT — most of the scale is given up in the first part of the drag, so
// the gesture reads as responsive immediately and then settles toward the
// floor. The floor lands at a full-screen-height drag, which is exactly where
// dampDragTranslation clamps translateY.
const DRAG_SCALE_FLOOR = 0.7;
const DRAG_SCALE_EXPONENT = 2;

// The reveal's corners open up as the page is dragged away. Radius is a native
// clip channel, so it animates on the same native clock as the rest of the
// window with no extra plumbing. Canonicalization scales it against the
// requested rectangle — 40 clears that at every window this overlay produces,
// including the
// 100pt-tall landing card.
const DRAG_MAX_RADIUS = 40;
const DRAG_RADIUS_RAMP_END = 0.875;

function clamp(value: number, minimum: number, maximum: number) {
  'worklet';
  return Math.min(maximum, Math.max(minimum, value));
}

function lerp(from: number, to: number, progress: number) {
  'worklet';
  return from + (to - from) * progress;
}

export function resolveDragContentScale(normalizedDrag: number) {
  'worklet';
  const progress = clamp(normalizedDrag, 0, 1);
  const rawFloor = DRAG_SCALE_FLOOR ** (1 / DRAG_SCALE_EXPONENT);

  return (1 + (rawFloor - 1) * progress) ** DRAG_SCALE_EXPONENT;
}

export function resolveDragClipRadius(
  normalizedDrag: number,
  sourceRadius: number,
  maximumDragRadius = DRAG_MAX_RADIUS
) {
  'worklet';
  const safeSourceRadius = Math.max(0, sourceRadius);
  const safeMaximumRadius = Math.max(0, maximumDragRadius);
  const progress = clamp(normalizedDrag / DRAG_RADIUS_RAMP_END, 0, 1);

  return lerp(safeSourceRadius, safeMaximumRadius, progress);
}

/**
 * Produces both the reveal window and the native content transform used by the
 * card-to-fullscreen overlay. It intentionally contains no layout state.
 *
 * The reveal window and its downward drag travel are untouched by the zoom: the
 * window still shrinks toward the minimum size and stays bottom-heavy via
 * `topClipRatio`. The drag additionally scales the CONTENT down. The content
 * translation compensates React Native's screen-centred scale origin so the
 * content shrinks toward the base rectangle's TOP edge — the window's top edge
 * only ever moves down from there, so the shrinking content can never pull away
 * from the window and expose what sits behind the overlay.
 */
export function calculateOverlayClipGeometry({
  progress,
  originX,
  originY,
  originWidth,
  originHeight,
  screenWidth,
  screenHeight,
  translateX,
  translateY,
  dragThreshold,
  minimumWidth,
  minimumHeight,
  topClipRatio,
  dragTranslateY,
  sourceRadius,
  maximumDragRadius,
}: OverlayClipGeometryInput): OverlayClipGeometryResult {
  'worklet';

  const revealProgress = clamp(progress, 0, 1);
  const positiveTranslateY = Math.max(0, translateY);
  const dragProgress =
    dragThreshold <= 0
      ? positiveTranslateY > 0
        ? 1
        : 0
      : clamp(positiveTranslateY / dragThreshold, 0, 1);
  const normalizedDrag =
    screenHeight <= 0 ? 0 : positiveTranslateY / screenHeight;

  const baseX = lerp(originX, 0, revealProgress);
  const baseY = lerp(originY, 0, revealProgress);
  const baseWidth = lerp(originWidth, screenWidth, revealProgress);
  const baseHeight = lerp(originHeight, screenHeight, revealProgress);
  const width = lerp(baseWidth, minimumWidth, dragProgress);
  const height = lerp(baseHeight, minimumHeight, dragProgress);
  const horizontalOffset = (baseWidth - width) / 2;
  const topOffset = (baseHeight - height) * topClipRatio;
  const contentDragY = lerp(0, dragTranslateY, dragProgress);
  const contentScale = resolveDragContentScale(normalizedDrag);

  return {
    clip: {
      x: baseX + horizontalOffset + translateX,
      y: baseY + topOffset + contentDragY,
      width,
      height,
      radius: resolveDragClipRadius(
        normalizedDrag,
        sourceRadius,
        maximumDragRadius
      ),
    },
    // Native scales the fixed fullscreen content container around its centre.
    // These terms re-anchor that scale onto the base rectangle: horizontally
    // centred, vertically pinned to its top edge. Both vanish at scale 1, so
    // every non-drag state is byte-identical.
    contentTranslateX:
      baseX + translateX - ((screenWidth - baseWidth) * (1 - contentScale)) / 2,
    contentTranslateY:
      baseY + contentDragY - (screenHeight * (1 - contentScale)) / 2,
    contentScale,
    // The reveal height a page cover would centre on, WITHOUT the drag's
    // shrink: such a cover lives inside the zoom transform, so it should ride
    // the zoom rather than re-centre against it. Only `progress` moves this,
    // which pins it while a drag is held and animates it once the drag is
    // released into a close.
    contentVisibleHeight: baseHeight,
  };
}
