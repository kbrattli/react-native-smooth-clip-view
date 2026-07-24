import type { ClipGeometry } from './geometry';

function px(value: number): string {
  'worklet';
  return `${value}px`;
}

/**
 * Creates a fixed-host CSS clip. Percentage/right/bottom anchored descendants
 * continue resolving against the host because this never changes its layout.
 */
export function createWebClipPath(geometry: ClipGeometry): string {
  'worklet';
  const width = Math.max(0, geometry.width);
  const height = Math.max(0, geometry.height);
  const left = Math.max(0, geometry.x);
  const top = Math.max(0, geometry.y);
  const rightEdge = Math.max(0, geometry.x + width);
  const bottomEdge = Math.max(0, geometry.y + height);
  const radius = Math.min(
    Math.max(0, geometry.radius),
    Math.min(width, height) / 2
  );

  return `inset(${px(top)} max(0px, calc(100% - ${px(
    rightEdge
  )})) max(0px, calc(100% - ${px(bottomEdge)})) ${px(
    left
  )} round ${px(radius)})`;
}
