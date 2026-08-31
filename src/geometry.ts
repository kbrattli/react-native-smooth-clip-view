/* eslint-disable no-bitwise -- React Native colors are converted to RRGGBBAA */
import type { ColorValue } from 'react-native';
import { processColor } from 'react-native-reanimated';

export type ClipCurve = 'circular' | 'continuous';

/** One numeric outset shadow following React Native's `boxShadow` field names. */
export type ClipBoxShadow = Readonly<{
  color?: ColorValue;
  offsetX: number;
  offsetY: number;
  /** CSS box-shadow blur radius. iOS converts this to CALayer radius / 2. */
  blurRadius?: number;
  spreadDistance?: number;
}>;

export type CanonicalClipBoxShadow = Readonly<{
  /** React Native numeric RRGGBBAA color; canonicalization is idempotent. */
  color: ColorValue;
  offsetX: number;
  offsetY: number;
  blurRadius: number;
  spreadDistance: number;
}>;

export type ClipGeometry = Readonly<{
  x: number;
  y: number;
  width: number;
  height: number;
  /** Default for every corner without an explicit override. */
  radius: number;
  topLeftRadius?: number;
  topRightRadius?: number;
  bottomRightRadius?: number;
  bottomLeftRadius?: number;
  curve?: ClipCurve;
}>;

export type CanonicalClipGeometry = Readonly<{
  x: number;
  y: number;
  width: number;
  height: number;
  /** Normalized all-corners value; zero when the corner radii differ. */
  radius: number;
  topLeftRadius: number;
  topRightRadius: number;
  bottomRightRadius: number;
  bottomLeftRadius: number;
  curve: ClipCurve;
}>;

export type ClipBounds = Readonly<{
  width: number;
  height: number;
}>;

export type SmoothClipPresentation = Readonly<{
  clip: ClipGeometry;
  contentTranslateX: number;
  contentTranslateY: number;
  /** Defaults to 1 when omitted. */
  contentScale?: number;
  boxShadow?: ClipBoxShadow;
}>;

export type CanonicalSmoothClipPresentation = Readonly<{
  clip: CanonicalClipGeometry;
  contentTranslateX: number;
  contentTranslateY: number;
  contentScale: number;
  boxShadow?: CanonicalClipBoxShadow;
}>;

const DEFAULT_SHADOW_COLOR = '#000000ff';

function isClipCurve(curve: ClipCurve | undefined): boolean {
  'worklet';
  return curve === undefined || curve === 'circular' || curve === 'continuous';
}

function isFiniteOptionalNumber(value: number | undefined): boolean {
  'worklet';
  return value === undefined || Number.isFinite(value);
}

function canonicalizeClipBoxShadow(
  shadow: ClipBoxShadow | undefined
): CanonicalClipBoxShadow | null | undefined {
  'worklet';
  if (shadow === undefined) return undefined;
  const { offsetX, offsetY } = shadow;
  const blurRadius = shadow.blurRadius ?? 0;
  const spreadDistance = shadow.spreadDistance ?? 0;
  if (
    !Number.isFinite(offsetX) ||
    !Number.isFinite(offsetY) ||
    !Number.isFinite(blurRadius) ||
    !Number.isFinite(spreadDistance)
  ) {
    return null;
  }
  const processedColor =
    shadow.color === undefined
      ? processColor(DEFAULT_SHADOW_COLOR)
      : processColor(shadow.color);
  // Platform and dynamic colors cannot be represented by the scalar native
  // animation protocol. Callers can resolve those colors before presenting.
  if (typeof processedColor !== 'number') return null;
  const unsignedProcessedColor = processedColor >>> 0;
  const color =
    ((unsignedProcessedColor << 8) | (unsignedProcessedColor >>> 24)) >>> 0;
  return {
    color: color as unknown as ColorValue,
    offsetX,
    offsetY,
    blurRadius: Math.max(0, blurRadius),
    spreadDistance,
  };
}

function clipBoxShadowEquals(
  first: ClipBoxShadow | undefined,
  second: ClipBoxShadow | undefined
): boolean {
  'worklet';
  if (first === undefined || second === undefined) return first === second;
  const canonicalFirst = canonicalizeClipBoxShadow(first);
  const canonicalSecond = canonicalizeClipBoxShadow(second);
  return (
    canonicalFirst !== null &&
    canonicalFirst !== undefined &&
    canonicalSecond !== null &&
    canonicalSecond !== undefined &&
    canonicalFirst.color === canonicalSecond.color &&
    canonicalFirst.offsetX === canonicalSecond.offsetX &&
    canonicalFirst.offsetY === canonicalSecond.offsetY &&
    canonicalFirst.blurRadius === canonicalSecond.blurRadius &&
    canonicalFirst.spreadDistance === canonicalSecond.spreadDistance
  );
}

export function isFiniteClipGeometry(geometry: ClipGeometry): boolean {
  'worklet';
  return (
    Number.isFinite(geometry.x) &&
    Number.isFinite(geometry.y) &&
    Number.isFinite(geometry.width) &&
    Number.isFinite(geometry.height) &&
    Number.isFinite(geometry.radius) &&
    isFiniteOptionalNumber(geometry.topLeftRadius) &&
    isFiniteOptionalNumber(geometry.topRightRadius) &&
    isFiniteOptionalNumber(geometry.bottomRightRadius) &&
    isFiniteOptionalNumber(geometry.bottomLeftRadius) &&
    isClipCurve(geometry.curve)
  );
}

function resolvedTopLeftRadius(geometry: ClipGeometry): number {
  'worklet';
  return geometry.topLeftRadius ?? geometry.radius;
}

function resolvedTopRightRadius(geometry: ClipGeometry): number {
  'worklet';
  return geometry.topRightRadius ?? geometry.radius;
}

function resolvedBottomRightRadius(geometry: ClipGeometry): number {
  'worklet';
  return geometry.bottomRightRadius ?? geometry.radius;
}

function resolvedBottomLeftRadius(geometry: ClipGeometry): number {
  'worklet';
  return geometry.bottomLeftRadius ?? geometry.radius;
}

function resolvedCurve(geometry: ClipGeometry): ClipCurve {
  'worklet';
  return geometry.curve ?? 'circular';
}

export function clipGeometryEquals(
  first: ClipGeometry | null,
  second: ClipGeometry
): boolean {
  'worklet';
  return (
    first !== null &&
    first.x === second.x &&
    first.y === second.y &&
    first.width === second.width &&
    first.height === second.height &&
    first.radius === second.radius &&
    resolvedTopLeftRadius(first) === resolvedTopLeftRadius(second) &&
    resolvedTopRightRadius(first) === resolvedTopRightRadius(second) &&
    resolvedBottomRightRadius(first) === resolvedBottomRightRadius(second) &&
    resolvedBottomLeftRadius(first) === resolvedBottomLeftRadius(second) &&
    resolvedCurve(first) === resolvedCurve(second)
  );
}

function resolvedContentScale(presentation: SmoothClipPresentation): number {
  'worklet';
  return presentation.contentScale ?? 1;
}

export function isFiniteClipPresentation(
  presentation: SmoothClipPresentation
): boolean {
  'worklet';
  const contentScale = resolvedContentScale(presentation);
  const shadow = canonicalizeClipBoxShadow(presentation.boxShadow);
  return (
    isFiniteClipGeometry(presentation.clip) &&
    Number.isFinite(presentation.contentTranslateX) &&
    Number.isFinite(presentation.contentTranslateY) &&
    Number.isFinite(contentScale) &&
    contentScale > 0 &&
    shadow !== null
  );
}

export function clipPresentationEquals(
  first: SmoothClipPresentation | null,
  second: SmoothClipPresentation
): boolean {
  'worklet';
  return (
    first !== null &&
    clipGeometryEquals(first.clip, second.clip) &&
    first.contentTranslateX === second.contentTranslateX &&
    first.contentTranslateY === second.contentTranslateY &&
    resolvedContentScale(first) === resolvedContentScale(second) &&
    clipBoxShadowEquals(first.boxShadow, second.boxShadow)
  );
}

function createCanonicalClipGeometry(
  geometry: ClipGeometry,
  x: number,
  y: number,
  width: number,
  height: number
): CanonicalClipGeometry {
  'worklet';
  const topLeftRadius = Math.max(0, resolvedTopLeftRadius(geometry));
  const topRightRadius = Math.max(0, resolvedTopRightRadius(geometry));
  const bottomRightRadius = Math.max(0, resolvedBottomRightRadius(geometry));
  const bottomLeftRadius = Math.max(0, resolvedBottomLeftRadius(geometry));

  // CSS corner-overlap reduction uses one common factor so all four corners
  // retain their proportions when either pair exceeds the available edge.
  let scale = 1;
  const top = topLeftRadius + topRightRadius;
  const right = topRightRadius + bottomRightRadius;
  const bottom = bottomLeftRadius + bottomRightRadius;
  const left = topLeftRadius + bottomLeftRadius;

  if (top > 0) scale = Math.min(scale, width / top);
  if (right > 0) scale = Math.min(scale, height / right);
  if (bottom > 0) scale = Math.min(scale, width / bottom);
  if (left > 0) scale = Math.min(scale, height / left);
  scale = Math.max(0, Math.min(1, scale));

  const normalizedTopLeftRadius = topLeftRadius * scale;
  const normalizedTopRightRadius = topRightRadius * scale;
  const normalizedBottomRightRadius = bottomRightRadius * scale;
  const normalizedBottomLeftRadius = bottomLeftRadius * scale;
  const radius =
    normalizedTopLeftRadius === normalizedTopRightRadius &&
    normalizedTopRightRadius === normalizedBottomRightRadius &&
    normalizedBottomRightRadius === normalizedBottomLeftRadius
      ? normalizedTopLeftRadius
      : 0;

  return {
    x,
    y,
    width,
    height,
    radius,
    topLeftRadius: normalizedTopLeftRadius,
    topRightRadius: normalizedTopRightRadius,
    bottomRightRadius: normalizedBottomRightRadius,
    bottomLeftRadius: normalizedBottomLeftRadius,
    curve: resolvedCurve(geometry),
  };
}

/**
 * Expands presentation defaults and applies CSS proportional corner scaling.
 */
export function canonicalizeClipGeometry(
  geometry: ClipGeometry
): CanonicalClipGeometry | null {
  'worklet';
  if (!isFiniteClipGeometry(geometry)) return null;

  const width = Math.max(0, geometry.width);
  const height = Math.max(0, geometry.height);
  return createCanonicalClipGeometry(
    geometry,
    geometry.x,
    geometry.y,
    width,
    height
  );
}

export function canonicalizeClipPresentation(
  presentation: SmoothClipPresentation
): CanonicalSmoothClipPresentation | null {
  'worklet';
  if (!isFiniteClipPresentation(presentation)) return null;

  const clip = canonicalizeClipGeometry(presentation.clip);
  if (clip === null) return null;
  const boxShadow = canonicalizeClipBoxShadow(presentation.boxShadow);
  if (boxShadow === null) return null;

  return {
    clip,
    contentTranslateX: presentation.contentTranslateX,
    contentTranslateY: presentation.contentTranslateY,
    contentScale: resolvedContentScale(presentation),
    ...(boxShadow === undefined ? {} : { boxShadow }),
  };
}

// Keep this below the canonicalization helpers so the worklet never closes
// over a helper declared later in this module.
export function createClipPresentation(
  clip: ClipGeometry,
  contentTranslateX = 0,
  contentTranslateY = 0,
  contentScale = 1,
  boxShadow?: ClipBoxShadow
): CanonicalSmoothClipPresentation {
  'worklet';
  const canonicalClip = canonicalizeClipGeometry(clip);
  const canonicalShadow = canonicalizeClipBoxShadow(boxShadow);
  return {
    // Keep invalid input observably invalid so downstream validation remains
    // atomic instead of accidentally sanitizing a required scalar.
    clip: canonicalClip ?? {
      x: clip.x,
      y: clip.y,
      width: clip.width,
      height: clip.height,
      radius: clip.radius,
      topLeftRadius: resolvedTopLeftRadius(clip),
      topRightRadius: resolvedTopRightRadius(clip),
      bottomRightRadius: resolvedBottomRightRadius(clip),
      bottomLeftRadius: resolvedBottomLeftRadius(clip),
      curve: resolvedCurve(clip),
    },
    contentTranslateX,
    contentTranslateY,
    contentScale,
    ...(canonicalShadow === undefined
      ? {}
      : {
          // Match the geometry constructor's invalid-input behavior: retain the
          // bad source value so the driver's atomic validation rejects it.
          boxShadow: (canonicalShadow ?? boxShadow) as CanonicalClipBoxShadow,
        }),
  };
}

/**
 * Mirrors the native geometry contract for tests and non-native fallbacks.
 * Native remains authoritative because its bounds are the actual rendered size.
 */
export function normalizeClipGeometry(
  geometry: ClipGeometry,
  bounds: ClipBounds
): CanonicalClipGeometry | null {
  'worklet';
  if (
    !isFiniteClipGeometry(geometry) ||
    !Number.isFinite(bounds.width) ||
    !Number.isFinite(bounds.height)
  ) {
    return null;
  }

  const boundsWidth = Math.max(0, bounds.width);
  const boundsHeight = Math.max(0, bounds.height);
  const requestedWidth = Math.max(0, geometry.width);
  const requestedHeight = Math.max(0, geometry.height);

  const left = Math.min(boundsWidth, Math.max(0, geometry.x));
  const top = Math.min(boundsHeight, Math.max(0, geometry.y));
  const right = Math.min(boundsWidth, Math.max(0, geometry.x + requestedWidth));
  const bottom = Math.min(
    boundsHeight,
    Math.max(0, geometry.y + requestedHeight)
  );
  const width = Math.max(0, right - left);
  const height = Math.max(0, bottom - top);

  return createCanonicalClipGeometry(geometry, left, top, width, height);
}

export function normalizeClipPresentation(
  presentation: SmoothClipPresentation,
  bounds: ClipBounds
): CanonicalSmoothClipPresentation | null {
  'worklet';
  if (!isFiniteClipPresentation(presentation)) return null;

  const clip = normalizeClipGeometry(presentation.clip, bounds);
  if (clip === null) return null;
  const boxShadow = canonicalizeClipBoxShadow(presentation.boxShadow);
  if (boxShadow === null) return null;

  return {
    clip,
    contentTranslateX: presentation.contentTranslateX,
    contentTranslateY: presentation.contentTranslateY,
    contentScale: resolvedContentScale(presentation),
    ...(boxShadow === undefined ? {} : { boxShadow }),
  };
}
