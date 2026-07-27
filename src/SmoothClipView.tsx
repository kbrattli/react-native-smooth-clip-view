import type React from 'react';
import { type ReactNode, useEffect } from 'react';
import { type ViewProps } from 'react-native';
import Animated, {
  dispatchCommand,
  useAnimatedReaction,
  useAnimatedRef,
} from 'react-native-reanimated';
import type { SmoothClipDriver } from './driverTypes';
import { getDriverState, registerDriverView } from './driverState';
import { clipPresentationEquals, isFiniteClipPresentation } from './geometry';
import NativeSmoothClipView, {
  type NativeProps,
} from './SmoothClipViewNativeComponent';

const AnimatedNativeSmoothClipView =
  Animated.createAnimatedComponent(NativeSmoothClipView);

export type SmoothClipViewProps = ViewProps & {
  driver: SmoothClipDriver;
  children?: ReactNode;
};

/** Android fallback. iOS resolves SmoothClipView.ios.tsx instead. */
export function SmoothClipView({
  driver,
  children,
  ...viewProps
}: SmoothClipViewProps) {
  const { driverId, initialPresentation, source } = getDriverState(driver);
  const { clip } = initialPresentation;
  useEffect(() => registerDriverView(driver), [driver]);
  const nativeRef =
    useAnimatedRef<React.ComponentRef<typeof NativeSmoothClipView>>();

  useAnimatedReaction(
    () => source.value,
    (presentation, previousPresentation) => {
      if (
        !isFiniteClipPresentation(presentation) ||
        clipPresentationEquals(previousPresentation, presentation)
      ) {
        return;
      }

      dispatchCommand(nativeRef, 'setClipPresentation', [
        presentation.clip.x,
        presentation.clip.y,
        presentation.clip.width,
        presentation.clip.height,
        presentation.clip.radius,
        presentation.contentTranslateX,
        presentation.contentTranslateY,
      ]);
    },
    [nativeRef, source]
  );

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
    <AnimatedNativeSmoothClipView ref={nativeRef} {...nativeProps}>
      {children}
    </AnimatedNativeSmoothClipView>
  );
}
