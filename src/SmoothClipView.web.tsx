import type { ReactNode } from 'react';
import { type ViewProps, type ViewStyle } from 'react-native';
import Animated, {
  useAnimatedReaction,
  useAnimatedStyle,
  useSharedValue,
  type SharedValue,
} from 'react-native-reanimated';
import {
  clipGeometryEquals,
  isFiniteClipGeometry,
  type ClipGeometry,
} from './geometry';
import { createWebClipPath } from './webClipPath';

export type SmoothClipViewProps = ViewProps & {
  initialClip: ClipGeometry;
  animatedClip: SharedValue<ClipGeometry>;
  children?: ReactNode;
};

/** Build-safe fallback. Web performance is intentionally outside the POC. */
export function SmoothClipView({
  initialClip,
  animatedClip,
  children,
  style,
  ...viewProps
}: SmoothClipViewProps) {
  const acceptedClip = useSharedValue(initialClip);
  const initialClipStyle = {
    clipPath: createWebClipPath(initialClip),
    overflow: 'hidden',
  } as unknown as ViewStyle;

  useAnimatedReaction(
    () => animatedClip.value,
    (clip, previousClip) => {
      if (
        isFiniteClipGeometry(clip) &&
        !clipGeometryEquals(previousClip, clip)
      ) {
        acceptedClip.value = clip;
      }
    },
    [animatedClip, acceptedClip]
  );

  const clipStyle = useAnimatedStyle(() => {
    const clip = acceptedClip.value;
    return {
      clipPath: createWebClipPath(clip),
      overflow: 'hidden',
    };
  });

  return (
    <Animated.View {...viewProps} style={[style, initialClipStyle, clipStyle]}>
      {children}
    </Animated.View>
  );
}
