import { useRouter, useSegments } from 'expo-router';
import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Image,
  Platform,
  StyleSheet,
  useWindowDimensions,
  View,
} from 'react-native';
import { useAnimatedReaction, useSharedValue } from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useReanimatedTransitionProgress } from 'react-native-screens/reanimated';
import { SmoothClipFlightTarget } from 'react-native-smooth-clip-view';
import { scheduleOnRN, scheduleOnUI } from 'react-native-worklets';
import {
  currentHeroFlight,
  setHeroWayBackCancel,
} from '../heroBench/flightBridge';
import {
  HeroBenchButton,
  HeroBenchControls,
  HeroBenchRow,
  heroBenchStyles,
} from '../heroBench/HeroBenchChrome';
import {
  HERO_EASE_IN_OUT_QUAD,
  HERO_FLIGHT_TAG,
  HERO_IMAGE,
  HERO_PLACEHOLDER,
  heroLayout,
  mixHeroPresentation,
} from '../heroBench/heroBenchGeometry';
import {
  heroBenchDuration,
  useHeroBenchSettings,
} from '../heroBench/heroBenchSettings';

/**
 * The run that ends the way back's interaction once the dismissal has
 * brought the hero to rest. Its length is only the time until the flight
 * lands (a spring would hold it in the flight layer while it settles).
 */
const SETTLE = {
  type: 'timing',
  duration: 100,
  controlPoints: HERO_EASE_IN_OUT_QUAD,
} as const;

/**
 * The destination of a flight, pushed with the native stack's default slide
 * (`hero-bench-flight`) or presented as a page sheet
 * (`hero-bench-flight-sheet`). The list card is already flying when this
 * mounts, so the hero (a `SmoothClipFlightTarget`) mounts hidden and is
 * revealed in the frame the flight lands.
 *
 * The way back follows this screen's own dismissal. react-native-screens
 * reports its transition progress per frame on the UI thread, for the
 * swipe-back gesture and for a sheet drag. When the dismissal begins,
 * the card's host begins an interaction: it lifts, starting from the frame it
 * landed on, and this hero is hidden. Each progress frame sets the hero
 * between the detail and the card. UIKit's own finish or cancel animation
 * keeps reporting progress after the finger lifts, so the hero arrives at
 * rest; a short run then ends the interaction, which lands the flight.
 */
export default function HeroBenchFlightDetail() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const { width, height } = useWindowDimensions();
  // An iOS sheet's content begins at the sheet's own top edge. (Android has
  // no page sheet: the route is a full screen there.)
  const route = useSegments().at(-1);
  const sheet = Platform.OS === 'ios' && route === 'hero-bench-flight-sheet';
  const layout = useMemo(
    () => heroLayout(width, height, sheet ? 0 : insets.top),
    [height, insets.top, sheet, width]
  );
  const [flight] = useState(currentHeroFlight);
  const durationMs = heroBenchDuration(useHeroBenchSettings());
  const transition = useReanimatedTransitionProgress();
  const following = useSharedValue(false);

  const beginWayBack = useCallback(() => {
    'worklet';
    if (flight === null || following.get()) return;
    following.set(true);
    flight.clip.ui.beginInteraction();
  }, [flight, following]);

  useAnimatedReaction(
    () => ({
      progress: transition.progress.get(),
      closing: transition.closing.get(),
    }),
    (now) => {
      if (flight === null || !now.closing) return;
      if (!following.get()) {
        if (now.progress >= 1) return;
        beginWayBack();
      }
      flight.clip.ui.setFrame(
        mixHeroPresentation(flight.detail, flight.card, now.progress)
      );
      if (now.progress >= 1) {
        following.set(false);
        flight.clip.ui.animateTo(flight.rest, SETTLE);
      }
    }
  );

  // A cancelled gesture: UIKit's cancel animation has brought the hero back
  // to the detail rect; land it there (this hero is revealed).
  useEffect(() => {
    if (flight === null) return;
    setHeroWayBackCancel(() =>
      scheduleOnUI(() => {
        'worklet';
        if (!following.get()) return;
        following.set(false);
        flight.clip.ui.animateTo(flight.detail, SETTLE);
      })
    );
    return () => setHeroWayBackCancel(null);
  }, [flight, following]);

  // Back pops from JS, which unmounts this route in the pop's own commit:
  // nothing here can follow that dismissal. So Back flies the card home with
  // a run instead (the way back: it starts from the frame the flight landed
  // on). It starts on the UI thread before the pop, so this hero is already
  // hidden in the snapshot react-native-screens animates.
  const back = useCallback(() => {
    if (flight === null) {
      router.back();
      return;
    }
    scheduleOnUI(() => {
      'worklet';
      flight.clip.ui.animateTo(flight.rest, {
        type: 'timing',
        duration: durationMs,
        controlPoints: HERO_EASE_IN_OUT_QUAD,
      });
      scheduleOnRN(router.back);
    });
  }, [durationMs, flight, router]);

  const { detail } = layout;
  return (
    <View style={heroBenchStyles.screen} testID="hero-bench-detail">
      <SmoothClipFlightTarget
        style={[
          styles.hero,
          {
            height: detail.height,
            left: detail.x,
            top: detail.y,
            width: detail.width,
          },
        ]}
        tag={HERO_FLIGHT_TAG}
      >
        {/* The placeholder paints inside the target, so it hides with it. */}
        <View style={styles.placeholder}>
          <Image resizeMode="cover" source={HERO_IMAGE} style={styles.image} />
        </View>
      </SmoothClipFlightTarget>
      <HeroBenchControls top={layout.controlsTop}>
        <HeroBenchRow>
          <HeroBenchButton
            label="Back"
            onPress={back}
            testID="hero-bench-back"
          />
        </HeroBenchRow>
      </HeroBenchControls>
    </View>
  );
}

const styles = StyleSheet.create({
  hero: { position: 'absolute' },
  placeholder: {
    backgroundColor: HERO_PLACEHOLDER,
    height: '100%',
    width: '100%',
  },
  image: { height: '100%', width: '100%' },
});
