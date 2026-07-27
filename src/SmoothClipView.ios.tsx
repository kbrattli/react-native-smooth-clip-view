import type { ReactNode } from 'react';
import { type ViewProps } from 'react-native';
import type { SmoothClipDriver } from './driverTypes';
import { getDriverState } from './driverState';
import NativeSmoothClipView, {
  type NativeProps,
} from './SmoothClipViewNativeComponent';

export type SmoothClipViewProps = ViewProps & {
  driver: SmoothClipDriver;
  children?: ReactNode;
};

export function SmoothClipView({
  driver,
  children,
  ...viewProps
}: SmoothClipViewProps) {
  const { driverId, initialPresentation } = getDriverState(driver);
  const { clip } = initialPresentation;
  const nativeProps: NativeProps = {
    ...viewProps,
    driverId,
    initialClipX: clip.x,
    initialClipY: clip.y,
    initialClipWidth: clip.width,
    initialClipHeight: clip.height,
    initialClipRadius: clip.radius,
    initialContentTranslateX: initialPresentation.contentTranslateX,
    initialContentTranslateY: initialPresentation.contentTranslateY,
  };

  return (
    <NativeSmoothClipView {...nativeProps}>{children}</NativeSmoothClipView>
  );
}
