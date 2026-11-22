import { useIsFocused, useRouter } from 'expo-router';
import { useCallback, useEffect, useMemo } from 'react';
import { Image, StyleSheet, useWindowDimensions, View } from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import Animated, {
  SharedTransition,
  SharedTransitionBoundary,
} from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import {
  SmoothClipView,
  useSmoothClipController,
} from 'react-native-smooth-clip-view';
import { scheduleOnRN } from 'react-native-worklets';
import { publishHeroFlight } from '../heroBench/flightBridge';
import {
  HeroBenchButton,
  HeroBenchControls,
  HeroBenchRow,
  heroBenchStyles,
} from '../heroBench/HeroBenchChrome';
import {
  HERO_CARD_RADIUS,
  HERO_EASE_IN_OUT_QUAD,
  HERO_FLIGHT_TAG,
  HERO_IMAGE,
  HERO_PLACEHOLDER,
  HERO_SHARED_TAG,
  heroCardPresentation,
  heroDetailPresentation,
  heroLayout,
  heroSheetTop,
  publishHeroLayout,
  type HeroLayout,
  type HeroRect,
} from '../heroBench/heroBenchGeometry';
import {
  blockJsThread,
  clearHeroBenchMarker,
  lightHeroBenchMarker,
} from '../heroBench/heroBenchProbe';
import {
  HERO_JS_BLOCK_MS,
  HERO_VARIANTS,
  heroBenchDuration,
  isFlightVariant,
  isSheetVariant,
  updateHeroBenchSettings,
  useHeroBenchSettings,
  type HeroVariant,
} from '../heroBench/heroBenchSettings';

const DETAIL_ROUTE: Record<HeroVariant, string> = {
  'set-push': '/hero-bench-set',
  'flight-push': '/hero-bench-flight',
  'set-sheet': '/hero-bench-set-sheet',
  'flight-sheet': '/hero-bench-flight-sheet',
};
/** The tap marker stays lit this long after the flight's duration. */
const MARKER_TAIL_MS = 700;

/**
 * The list screen: one card that opens a detail hero, with Reanimated's
 * shared element transition or with a SmoothClipView flight.
 *
 * Both start from the same UI-thread Tap. The flight starts its run in that
 * worklet, in the main-thread turn that delivers the touch-up; SET starts in
 * the mount of the navigation commit, so it waits for the JS thread.
 */
export default function HeroBenchScreen() {
  const router = useRouter();
  const isFocused = useIsFocused();
  const insets = useSafeAreaInsets();
  const { width, height } = useWindowDimensions();
  const settings = useHeroBenchSettings();
  const { variant, jsBlock } = settings;
  const sheet = isSheetVariant(variant);
  const flight = isFlightVariant(variant);
  const durationMs = heroBenchDuration(settings);
  const layout = useMemo(
    () =>
      heroLayout(
        width,
        height,
        insets.top,
        sheet ? heroSheetTop(insets.top) : insets.top
      ),
    [height, insets.top, sheet, width]
  );
  useEffect(() => {
    publishHeroLayout(layout, width, height);
  }, [height, layout, width]);

  const open = useCallback(() => {
    router.push(DETAIL_ROUTE[variant] as never);
    setTimeout(clearHeroBenchMarker, durationMs + MARKER_TAIL_MS);
  }, [durationMs, router, variant]);

  const setTap = useMemo(
    () => cardTap({ jsBlock, open, start: undefined }),
    [jsBlock, open]
  );

  const { card } = layout;
  return (
    <SharedTransitionBoundary isActive={isFocused}>
      <View style={heroBenchStyles.screen} testID="hero-bench-screen">
        {flight ? (
          // Keyed: each scenario seeds its own host and controller.
          <FlightCard
            durationMs={durationMs}
            jsBlock={jsBlock}
            key={variant}
            layout={layout}
            open={open}
          />
        ) : (
          <GestureDetector gesture={setTap}>
            <View
              style={[styles.card, cardStyle(card)]}
              testID="hero-bench-card"
            >
              <Animated.Image
                resizeMode="cover"
                sharedTransitionStyle={SharedTransition.duration(durationMs)}
                sharedTransitionTag={HERO_SHARED_TAG}
                source={HERO_IMAGE}
                style={styles.cardImage}
              />
            </View>
          </GestureDetector>
        )}

        <HeroBenchControls top={layout.controlsTop}>
          <HeroBenchRow>
            {HERO_VARIANTS.map((option) => (
              <HeroBenchButton
                key={option.value}
                label={option.label}
                onPress={() =>
                  updateHeroBenchSettings({ variant: option.value })
                }
                selected={variant === option.value}
                testID={`hero-bench-variant-${option.value}`}
              />
            ))}
          </HeroBenchRow>
          <HeroBenchRow>
            {[0, 14].map((busyMs) => (
              <HeroBenchButton
                key={busyMs}
                label={`Busy ${busyMs}`}
                onPress={() => updateHeroBenchSettings({ busyMs })}
                selected={settings.busyMs === busyMs}
                testID={`hero-bench-busy-${busyMs}`}
              />
            ))}
            <HeroBenchButton
              label="JS block"
              onPress={() => updateHeroBenchSettings({ jsBlock: !jsBlock })}
              selected={jsBlock}
              testID="hero-bench-js-block"
            />
            <HeroBenchButton
              label="Slow"
              onPress={() => updateHeroBenchSettings({ slow: !settings.slow })}
              selected={settings.slow}
              testID="hero-bench-slow"
            />
            <HeroBenchButton
              label="Exit"
              onPress={() => router.back()}
              testID="hero-bench-exit"
            />
          </HeroBenchRow>
        </HeroBenchControls>
      </View>
    </SharedTransitionBoundary>
  );
}

function cardStyle(card: HeroRect) {
  return {
    height: card.height,
    left: card.x,
    top: card.y,
    width: card.width,
  };
}

/**
 * The card's UI-thread tap, the same for SET and for a flight: light the
 * marker, start the flight (`start`, flights only), then hand over to JS.
 */
function cardTap({
  jsBlock,
  open,
  start,
}: {
  jsBlock: boolean;
  open: () => void;
  start: (() => void) | undefined;
}) {
  return Gesture.Tap().onEnd((_event, success) => {
    'worklet';
    if (!success) return;
    lightHeroBenchMarker();
    start?.();
    if (jsBlock) scheduleOnRN(blockJsThread, HERO_JS_BLOCK_MS);
    scheduleOnRN(open);
  });
}

/**
 * The card as a flight host: a window-sized SmoothClipView whose content is
 * laid out as the detail hero, seeded on the card. The tap starts its run on
 * the UI thread; the detail route's `SmoothClipFlightTarget` takes over when
 * the flight lands, and flies it home through `flightBridge`.
 */
function FlightCard({
  durationMs,
  jsBlock,
  layout,
  open,
}: {
  durationMs: number;
  jsBlock: boolean;
  layout: HeroLayout;
  open: () => void;
}) {
  const { width, height } = useWindowDimensions();
  const cardFrame = useMemo(
    () => heroCardPresentation(layout, width, height),
    [height, layout, width]
  );
  // In window space: the destination's pixels wherever this screen sits.
  const detailFrame = useMemo(
    () => ({ ...heroDetailPresentation(layout), space: 'window' as const }),
    [layout]
  );
  const clip = useSmoothClipController(cardFrame);
  useEffect(() => {
    publishHeroFlight({
      clip,
      detail: detailFrame,
      card: { ...cardFrame, space: 'window' },
      rest: cardFrame,
    });
    return () => publishHeroFlight(null);
  }, [cardFrame, clip, detailFrame]);

  const tap = useMemo(
    () =>
      cardTap({
        jsBlock,
        open,
        start: () => {
          'worklet';
          clip.ui.animateTo(detailFrame, {
            type: 'timing',
            duration: durationMs,
            controlPoints: HERO_EASE_IN_OUT_QUAD,
          });
        },
      }),
    [clip, detailFrame, durationMs, jsBlock, open]
  );

  const { card, detail } = layout;
  return (
    <>
      <GestureDetector gesture={tap}>
        <View style={[styles.card, cardStyle(card)]} testID="hero-bench-card" />
      </GestureDetector>
      <SmoothClipView
        controller={clip}
        flight={HERO_FLIGHT_TAG}
        pointerEvents="none"
        style={StyleSheet.absoluteFill}
        testID="hero-bench-flight-host"
      >
        <View style={[styles.hero, cardStyle(detail)]}>
          <Image resizeMode="cover" source={HERO_IMAGE} style={styles.fill} />
        </View>
      </SmoothClipView>
    </>
  );
}

const styles = StyleSheet.create({
  card: { position: 'absolute' },
  cardImage: {
    backgroundColor: HERO_PLACEHOLDER,
    borderRadius: HERO_CARD_RADIUS,
    height: '100%',
    overflow: 'hidden',
    width: '100%',
  },
  fill: { height: '100%', width: '100%' },
  hero: { backgroundColor: HERO_PLACEHOLDER, position: 'absolute' },
});
