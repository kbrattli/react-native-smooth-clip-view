import { useIsFocused, useRouter, useSegments } from 'expo-router';
import { useMemo } from 'react';
import { Platform, StyleSheet, useWindowDimensions, View } from 'react-native';
import Animated, {
  SharedTransition,
  SharedTransitionBoundary,
} from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import {
  HeroBenchButton,
  HeroBenchControls,
  HeroBenchRow,
  heroBenchStyles,
} from '../heroBench/HeroBenchChrome';
import {
  HERO_IMAGE,
  HERO_PLACEHOLDER,
  HERO_SHARED_TAG,
  heroLayout,
} from '../heroBench/heroBenchGeometry';
import {
  heroBenchDuration,
  useHeroBenchSettings,
} from '../heroBench/heroBenchSettings';

/**
 * Reanimated 4.8 shared element target, pushed with the native stack's
 * default slide (`hero-bench-set`) or presented as a page sheet
 * (`hero-bench-set-sheet`). The screen's boundary becomes the topmost active
 * one in the commit that mounts it, which starts the transition from the
 * card's on-screen frame. Reanimated follows the swipe-back gesture itself.
 */
export default function HeroBenchSetDetail() {
  const router = useRouter();
  const isFocused = useIsFocused();
  const insets = useSafeAreaInsets();
  const { width, height } = useWindowDimensions();
  // An iOS sheet's content begins at the sheet's own top edge. (Android has
  // no page sheet: the route is a full screen there.)
  const route = useSegments().at(-1);
  const sheet = Platform.OS === 'ios' && route === 'hero-bench-set-sheet';
  const layout = useMemo(
    () => heroLayout(width, height, sheet ? 0 : insets.top),
    [height, insets.top, sheet, width]
  );
  const durationMs = heroBenchDuration(useHeroBenchSettings());
  const { detail } = layout;

  return (
    <SharedTransitionBoundary isActive={isFocused}>
      <View style={heroBenchStyles.screen} testID="hero-bench-detail">
        <Animated.Image
          resizeMode="cover"
          sharedTransitionStyle={SharedTransition.duration(durationMs)}
          sharedTransitionTag={HERO_SHARED_TAG}
          source={HERO_IMAGE}
          style={[
            styles.hero,
            {
              height: detail.height,
              left: detail.x,
              top: detail.y,
              width: detail.width,
            },
          ]}
        />
        <HeroBenchControls top={layout.controlsTop}>
          <HeroBenchRow>
            <HeroBenchButton
              label="Back"
              onPress={() => router.back()}
              testID="hero-bench-back"
            />
          </HeroBenchRow>
        </HeroBenchControls>
      </View>
    </SharedTransitionBoundary>
  );
}

const styles = StyleSheet.create({
  hero: {
    backgroundColor: HERO_PLACEHOLDER,
    borderRadius: 0,
    position: 'absolute',
  },
});
