import type React from 'react';
import type { ReactNode } from 'react';
import type { ViewProps } from 'react-native';
import Animated, {
  dispatchCommand,
  useAnimatedReaction,
  useAnimatedRef,
  type SharedValue,
} from 'react-native-reanimated';
import NativeSmoothClipView from '../../../src/SmoothClipViewNativeComponent';
import {
  clipGeometryEquals,
  isFiniteClipGeometry,
  type ClipGeometry,
} from '../../../src/geometry';

const AnimatedNativeSmoothClipView =
  Animated.createAnimatedComponent(NativeSmoothClipView);

type LegacySmoothClipViewProps = ViewProps & {
  animatedClip: SharedValue<ClipGeometry>;
  initialClip: ClipGeometry;
  children?: ReactNode;
};

export function LegacySmoothClipView({
  animatedClip,
  initialClip,
  children,
  ...viewProps
}: LegacySmoothClipViewProps) {
  const nativeRef =
    useAnimatedRef<React.ComponentRef<typeof NativeSmoothClipView>>();

  useAnimatedReaction(
    () => animatedClip.value,
    (clip, previousClip) => {
      if (
        isFiniteClipGeometry(clip) &&
        !clipGeometryEquals(previousClip, clip)
      ) {
        dispatchCommand(nativeRef, 'setClipGeometry', [
          clip.x,
          clip.y,
          clip.width,
          clip.height,
          clip.radius,
        ]);
      }
    },
    [animatedClip, nativeRef]
  );

  return (
    <AnimatedNativeSmoothClipView
      {...viewProps}
      driverId={0}
      initialClipX={initialClip.x}
      initialClipY={initialClip.y}
      initialClipWidth={initialClip.width}
      initialClipHeight={initialClip.height}
      initialClipRadius={initialClip.radius}
      initialContentTranslateX={0}
      initialContentTranslateY={0}
      ref={nativeRef}
    >
      {children}
    </AnimatedNativeSmoothClipView>
  );
}
