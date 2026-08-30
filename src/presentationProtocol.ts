import type { CanonicalSmoothClipPresentation } from './geometry';

export function isV1CompatiblePresentation(
  presentation: CanonicalSmoothClipPresentation
): boolean {
  const { clip } = presentation;
  return (
    clip.curve === 'circular' &&
    clip.topLeftRadius === clip.radius &&
    clip.topRightRadius === clip.radius &&
    clip.bottomRightRadius === clip.radius &&
    clip.bottomLeftRadius === clip.radius &&
    presentation.contentScale === 1
  );
}

export function assertInitialPresentationProtocol(
  presentation: CanonicalSmoothClipPresentation,
  protocolVersion: 1 | 2
): void {
  if (protocolVersion === 2 || isV1CompatiblePresentation(presentation)) {
    return;
  }

  throw new Error(
    '[SmoothClipView] The initial presentation requires native presentation protocol V2, but the installed native library only supports V1. Rebuild the native app or select an explicit streaming fallback.'
  );
}
