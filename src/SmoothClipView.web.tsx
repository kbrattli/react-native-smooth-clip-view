import { type ReactNode, useEffect } from 'react';
import { type ViewProps, type ViewStyle } from 'react-native';
import Animated, {
  useAnimatedReaction,
  useAnimatedStyle,
  useSharedValue,
} from 'react-native-reanimated';
import type { SmoothClipDriver } from './driverTypes';
import { getDriverState, registerDriverView } from './driverState';
import { clipPresentationEquals, isFiniteClipPresentation } from './geometry';
import { createWebClipPath } from './webClipPath';

export type SmoothClipViewProps = ViewProps & {
  driver: SmoothClipDriver;
  children?: ReactNode;
};

/** Fixed-layout CSS fallback. */
export function SmoothClipView({
  driver,
  children,
  style,
  ...viewProps
}: SmoothClipViewProps) {
  const { initialPresentation, source } = getDriverState(driver);
  useEffect(() => registerDriverView(driver), [driver]);
  const acceptedPresentation = useSharedValue(initialPresentation);
  const initialClipStyle = {
    clipPath: createWebClipPath(initialPresentation.clip),
    overflow: 'hidden',
  } as unknown as ViewStyle;

  useAnimatedReaction(
    () => source.value,
    (presentation, previousPresentation) => {
      if (
        isFiniteClipPresentation(presentation) &&
        !clipPresentationEquals(previousPresentation, presentation)
      ) {
        acceptedPresentation.value = presentation;
      }
    },
    [source, acceptedPresentation]
  );

  const clipStyle = useAnimatedStyle(() => {
    const clip = acceptedPresentation.value.clip;
    return {
      clipPath: createWebClipPath(clip),
      overflow: 'hidden',
    };
  });

  const contentStyle = useAnimatedStyle(() => ({
    transform: [
      { translateX: acceptedPresentation.value.contentTranslateX },
      { translateY: acceptedPresentation.value.contentTranslateY },
    ],
  }));

  return (
    <Animated.View {...viewProps} style={[style, initialClipStyle, clipStyle]}>
      <Animated.View style={contentStyle}>{children}</Animated.View>
    </Animated.View>
  );
}
