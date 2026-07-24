export type ClipGeometry = Readonly<{
  x: number;
  y: number;
  width: number;
  height: number;
  radius: number;
}>;

export type ClipBounds = Readonly<{
  width: number;
  height: number;
}>;

export function isFiniteClipGeometry(geometry: ClipGeometry): boolean {
  'worklet';
  return (
    Number.isFinite(geometry.x) &&
    Number.isFinite(geometry.y) &&
    Number.isFinite(geometry.width) &&
    Number.isFinite(geometry.height) &&
    Number.isFinite(geometry.radius)
  );
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
    first.radius === second.radius
  );
}

/**
 * Mirrors the native geometry contract for tests and non-native fallbacks.
 * Native remains authoritative because its bounds are the actual rendered size.
 */
export function normalizeClipGeometry(
  geometry: ClipGeometry,
  bounds: ClipBounds
): ClipGeometry | null {
  'worklet';
  const values = [
    geometry.x,
    geometry.y,
    geometry.width,
    geometry.height,
    geometry.radius,
    bounds.width,
    bounds.height,
  ];

  if (!values.every(Number.isFinite)) return null;

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

  return {
    x: left,
    y: top,
    width,
    height,
    radius: Math.min(Math.max(0, geometry.radius), Math.min(width, height) / 2),
  };
}
