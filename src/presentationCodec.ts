/* eslint-disable no-bitwise -- the native packet carries packed RRGGBBAA colors */
import type { CanonicalSmoothClipPresentation } from './geometry';

/**
 * Versionless native packet layout. Keep this as the single JS codec used by
 * drivers, groups, snapshots, and cancellation.
 */
export const PRESENTATION_STRIDE = 21;

export function appendPresentationPacket(
  values: number[],
  presentation: CanonicalSmoothClipPresentation
): void {
  'worklet';
  const {
    clip,
    contentTranslateX,
    contentTranslateY,
    contentScale,
    boxShadow,
  } = presentation;
  const color = ((boxShadow?.color as unknown as number) ?? 0x000000ff) >>> 0;
  values.push(
    clip.x,
    clip.y,
    clip.width,
    clip.height,
    clip.topLeftRadius,
    clip.topRightRadius,
    clip.bottomRightRadius,
    clip.bottomLeftRadius,
    clip.curve === 'continuous' ? 1 : 0,
    contentTranslateX,
    contentTranslateY,
    contentScale,
    boxShadow === undefined ? 0 : 1,
    ((color >>> 24) & 0xff) / 255,
    ((color >>> 16) & 0xff) / 255,
    ((color >>> 8) & 0xff) / 255,
    (color & 0xff) / 255,
    boxShadow?.offsetX ?? 0,
    boxShadow?.offsetY ?? 0,
    boxShadow?.blurRadius ?? 0,
    boxShadow?.spreadDistance ?? 0
  );
}

export function presentationPacket(
  presentation: CanonicalSmoothClipPresentation
): number[] {
  'worklet';
  const values: number[] = [];
  appendPresentationPacket(values, presentation);
  return values;
}

export function presentationFromPacket(
  values: readonly number[],
  offset = 0
): CanonicalSmoothClipPresentation | null {
  'worklet';
  if (values.length < offset + PRESENTATION_STRIDE) return null;
  for (let index = offset; index < offset + PRESENTATION_STRIDE; index += 1) {
    if (!Number.isFinite(values[index])) return null;
  }
  const topLeftRadius = values[offset + 4] as number;
  const topRightRadius = values[offset + 5] as number;
  const bottomRightRadius = values[offset + 6] as number;
  const bottomLeftRadius = values[offset + 7] as number;
  const curveCode = values[offset + 8] as number;
  const contentScale = values[offset + 11] as number;
  const shadowEnabledCode = values[offset + 12] as number;
  const red = values[offset + 13] as number;
  const green = values[offset + 14] as number;
  const blue = values[offset + 15] as number;
  const alpha = values[offset + 16] as number;
  const blurRadius = values[offset + 19] as number;
  if (
    (curveCode !== 0 && curveCode !== 1) ||
    contentScale <= 0 ||
    (shadowEnabledCode !== 0 && shadowEnabledCode !== 1) ||
    red < 0 ||
    red > 1 ||
    green < 0 ||
    green > 1 ||
    blue < 0 ||
    blue > 1 ||
    alpha < 0 ||
    alpha > 1 ||
    blurRadius < 0
  ) {
    return null;
  }
  const shadowEnabled = shadowEnabledCode === 1;
  const color =
    ((Math.round(red * 255) << 24) |
      (Math.round(green * 255) << 16) |
      (Math.round(blue * 255) << 8) |
      Math.round(alpha * 255)) >>>
    0;
  return {
    clip: {
      x: values[offset] as number,
      y: values[offset + 1] as number,
      width: values[offset + 2] as number,
      height: values[offset + 3] as number,
      radius:
        topLeftRadius === topRightRadius &&
        topLeftRadius === bottomRightRadius &&
        topLeftRadius === bottomLeftRadius
          ? topLeftRadius
          : 0,
      topLeftRadius,
      topRightRadius,
      bottomRightRadius,
      bottomLeftRadius,
      curve: curveCode === 1 ? 'continuous' : 'circular',
    },
    contentTranslateX: values[offset + 9] as number,
    contentTranslateY: values[offset + 10] as number,
    contentScale,
    ...(shadowEnabled
      ? {
          boxShadow: {
            color,
            offsetX: values[offset + 17] as number,
            offsetY: values[offset + 18] as number,
            blurRadius,
            spreadDistance: values[offset + 20] as number,
          },
        }
      : {}),
  };
}
