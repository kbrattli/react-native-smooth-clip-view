import { forwardRef, type ComponentRef, type ReactNode } from 'react';
import { type ViewProps } from 'react-native';
import type { SmoothClipDriver } from './driverTypes';
import { getDriverState } from './driverState';
import { getSmoothClipCapabilities } from './capabilities';
import { canonicalizeClipPresentation } from './geometry';
import { assertInitialPresentationProtocol } from './presentationProtocol';
import NativeSmoothClipView, {
  type NativeProps,
} from './SmoothClipViewNativeComponent';

export type SmoothClipViewProps = ViewProps & {
  driver: SmoothClipDriver;
  children?: ReactNode;
};

export const SmoothClipView = forwardRef<
  ComponentRef<typeof NativeSmoothClipView>,
  SmoothClipViewProps
>(function SmoothClipViewComponent(
  { driver, children, ...viewProps },
  forwardedRef
) {
  const { driverId, initialPresentation } = getDriverState(driver);
  const canonical = canonicalizeClipPresentation(initialPresentation);
  if (canonical === null) return null;
  const { clip } = canonical;
  const protocolVersion =
    getSmoothClipCapabilities().presentationProtocolVersion;
  assertInitialPresentationProtocol(canonical, protocolVersion);
  const nativeProps: NativeProps = {
    ...viewProps,
    driverId,
    initialClipX: clip.x,
    initialClipY: clip.y,
    initialClipWidth: clip.width,
    initialClipHeight: clip.height,
    initialClipRadius: clip.radius,
    presentationVersion: protocolVersion,
    initialClipTopLeftRadius: clip.topLeftRadius,
    initialClipTopRightRadius: clip.topRightRadius,
    initialClipBottomRightRadius: clip.bottomRightRadius,
    initialClipBottomLeftRadius: clip.bottomLeftRadius,
    initialClipCurve: clip.curve === 'continuous' ? 1 : 0,
    initialContentTranslateX: canonical.contentTranslateX,
    initialContentTranslateY: canonical.contentTranslateY,
    initialContentScale: canonical.contentScale,
  };

  return (
    <NativeSmoothClipView ref={forwardedRef} {...nativeProps}>
      {children}
    </NativeSmoothClipView>
  );
});
