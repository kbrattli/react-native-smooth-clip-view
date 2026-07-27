import type { ClipGeometry } from 'react-native-smooth-clip-view';

const COLLAPSED_WIDTH_RATIO = 0.62;
const COLLAPSED_HEIGHT_RATIO = 0.68;

export const STRESS_EXPANDED_CLIP_RADIUS = 18;

export function getStressClipGeometry(
  progress: number,
  maximumWidth: number,
  maximumHeight: number
): ClipGeometry {
  'worklet';

  const clampedProgress = Math.min(1, Math.max(0, progress));
  const remaining = 1 - clampedProgress;
  const collapsedDiameter = Math.min(
    maximumWidth * COLLAPSED_WIDTH_RATIO,
    maximumHeight * COLLAPSED_HEIGHT_RATIO
  );
  const collapsedX = (maximumWidth - collapsedDiameter) / 2;
  const collapsedY = (maximumHeight - collapsedDiameter) / 2;
  const collapsedRadius = collapsedDiameter / 2;

  return {
    x: collapsedX * remaining,
    y: collapsedY * remaining,
    width:
      collapsedDiameter + (maximumWidth - collapsedDiameter) * clampedProgress,
    height:
      collapsedDiameter + (maximumHeight - collapsedDiameter) * clampedProgress,
    radius:
      collapsedRadius +
      (STRESS_EXPANDED_CLIP_RADIUS - collapsedRadius) * clampedProgress,
  };
}
