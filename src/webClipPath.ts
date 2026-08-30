import {
  normalizeClipGeometry,
  type CanonicalClipGeometry,
  type ClipBounds,
  type ClipGeometry,
} from './geometry';

const CIRCULAR_KAPPA = (4 * (Math.SQRT2 - 1)) / 3;

export const WEB_CONTENT_CONTAINER_STYLE = Object.freeze({
  width: '100%',
  height: '100%',
  transformOrigin: '50% 50%',
});

function px(value: number): string {
  'worklet';
  return `${value}px`;
}

function n(value: number): string {
  'worklet';
  return Number(value.toFixed(4)).toString();
}

/** Fixed-topology clockwise path shared with the native complex-path shape. */
function createPortableClipPathFromNormalized(
  clip: CanonicalClipGeometry
): string {
  'worklet';
  if (clip.width <= 0 || clip.height <= 0) {
    return 'M 0 0 Z';
  }

  const left = clip.x;
  const top = clip.y;
  const right = left + clip.width;
  const bottom = top + clip.height;
  const tl = clip.topLeftRadius;
  const tr = clip.topRightRadius;
  const br = clip.bottomRightRadius;
  const bl = clip.bottomLeftRadius;
  const k = clip.curve === 'continuous' ? 1 : CIRCULAR_KAPPA;
  const oneMinusK = 1 - k;

  return [
    `M ${n(left + tl)} ${n(top)}`,
    `L ${n(right - tr)} ${n(top)}`,
    `C ${n(right - tr * oneMinusK)} ${n(top)} ${n(right)} ${n(
      top + tr * oneMinusK
    )} ${n(right)} ${n(top + tr)}`,
    `L ${n(right)} ${n(bottom - br)}`,
    `C ${n(right)} ${n(bottom - br * oneMinusK)} ${n(
      right - br * oneMinusK
    )} ${n(bottom)} ${n(right - br)} ${n(bottom)}`,
    `L ${n(left + bl)} ${n(bottom)}`,
    `C ${n(left + bl * oneMinusK)} ${n(bottom)} ${n(left)} ${n(
      bottom - bl * oneMinusK
    )} ${n(left)} ${n(bottom - bl)}`,
    `L ${n(left)} ${n(top + tl)}`,
    `C ${n(left)} ${n(top + tl * oneMinusK)} ${n(
      left + tl * oneMinusK
    )} ${n(top)} ${n(left + tl)} ${n(top)}`,
    'Z',
  ].join(' ');
}

export function createPortableClipPath(
  geometry: ClipGeometry,
  bounds: ClipBounds
): string {
  'worklet';
  const clip = normalizeClipGeometry(geometry, bounds);
  return clip === null ? 'M 0 0 Z' : createPortableClipPathFromNormalized(clip);
}

/**
 * Creates a fixed-host CSS clip. Percentage/right/bottom anchored descendants
 * continue resolving against the host because this never changes its layout.
 */
export function createWebClipPath(
  geometry: ClipGeometry,
  bounds: ClipBounds
): string {
  'worklet';
  const clip = normalizeClipGeometry(geometry, bounds);
  if (clip === null) return 'path("M 0 0 Z")';
  const uniform =
    clip.topLeftRadius === clip.topRightRadius &&
    clip.topLeftRadius === clip.bottomRightRadius &&
    clip.topLeftRadius === clip.bottomLeftRadius;
  if (clip.curve === 'circular' && uniform) {
    const left = Math.max(0, clip.x);
    const top = Math.max(0, clip.y);
    const rightEdge = Math.max(0, clip.x + clip.width);
    const bottomEdge = Math.max(0, clip.y + clip.height);
    return `inset(${px(top)} max(0px, calc(100% - ${px(
      rightEdge
    )})) max(0px, calc(100% - ${px(bottomEdge)})) ${px(
      left
    )} round ${px(clip.radius)})`;
  }
  return `path("${createPortableClipPathFromNormalized(clip)}")`;
}
