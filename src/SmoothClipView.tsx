import type React from 'react';
import type { ReactNode } from 'react';
import { type ViewProps } from 'react-native';
import Animated, {
  dispatchCommand,
  useAnimatedReaction,
  useAnimatedRef,
  type SharedValue,
} from 'react-native-reanimated';
import NativeSmoothClipView, {
  type NativeProps,
} from './SmoothClipViewNativeComponent';
import {
  clipGeometryEquals,
  isFiniteClipGeometry,
  type ClipGeometry,
} from './geometry';

const AnimatedNativeSmoothClipView =
  Animated.createAnimatedComponent(NativeSmoothClipView);

export type SmoothClipViewProps = ViewProps & {
  initialClip: ClipGeometry;
  animatedClip: SharedValue<ClipGeometry>;
  children?: ReactNode;
};

export function SmoothClipView({
  initialClip,
  animatedClip,
  children,
  ...viewProps
}: SmoothClipViewProps) {
  const nativeRef =
    useAnimatedRef<React.ComponentRef<typeof NativeSmoothClipView>>();

  useAnimatedReaction(
    () => animatedClip.value,
    (clip, previousClip) => {
      if (
        !isFiniteClipGeometry(clip) ||
        clipGeometryEquals(previousClip, clip)
      ) {
        return;
      }

      dispatchCommand(nativeRef, 'setClipGeometry', [
        clip.x,
        clip.y,
        clip.width,
        clip.height,
        clip.radius,
      ]);
    },
    [nativeRef, animatedClip]
  );

  const nativeProps: NativeProps = {
    ...viewProps,
    initialClipX: initialClip.x,
    initialClipY: initialClip.y,
    initialClipWidth: initialClip.width,
    initialClipHeight: initialClip.height,
    initialClipRadius: initialClip.radius,
  };

  return (
    <AnimatedNativeSmoothClipView ref={nativeRef} {...nativeProps}>
      {children}
    </AnimatedNativeSmoothClipView>
  );
}
