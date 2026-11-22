import { Stack, useRouter } from 'expo-router';
import { useCallback, useEffect, useMemo } from 'react';
import { StyleSheet, useWindowDimensions, View } from 'react-native';
import { GestureDetector } from 'react-native-gesture-handler';
import Animated, {
  makeMutable,
  useAnimatedProps,
  useAnimatedReaction,
  withDelay,
  withTiming,
  type SharedValue,
} from 'react-native-reanimated';
import {
  SmoothClipFlightTarget,
  SmoothClipView,
  useSmoothClipController,
  type SmoothClipController,
  type SmoothClipPresentation,
} from 'react-native-smooth-clip-view';
import { Portal, PortalHost, PortalProvider } from 'react-native-teleport';
import { scheduleOnRN, scheduleOnUI } from 'react-native-worklets';
import type { GalleryImage } from '../galleryImages';
import {
  HERO_EASE_IN_OUT_QUAD,
  type HeroRect,
} from '../heroBench/heroBenchGeometry';
import {
  GALLERY_DURATION_MS,
  GalleryDetailScreen,
  GalleryGridScreen,
  GalleryPhoto,
  galleryStyles,
  galleryTileTap,
  scheduleGalleryMarkerClear,
  useGalleryLayout,
} from './GalleryBench';
import {
  GALLERY_BACKGROUND,
  galleryDetailPresentation,
  galleryTilePresentation,
  rectStyle,
  type GalleryLayout,
} from './galleryBenchGeometry';

/**
 * The SmoothClipView variants of the gallery bench
 * (docs/gallery-mount-time.md). Every tile is a flight host (`flight` + a
 * controller), as in the hero bench: a window-sized SmoothClipView whose
 * photo is laid out at the detail rect and cropped into the tile. The tap
 * starts the run in its UI-thread worklet, then pushes the detail, whose
 * `SmoothClipFlightTarget` takes over when the flight lands.
 *
 * With teleport (react-native-teleport added by hand: the library has no
 * teleport mode), the detail renders no photo of its own. Its target holds a
 * `PortalHost`, and the tile's live photo is teleported into it when the
 * flight lands, and back into its host when it leaves. One UI-thread value
 * per tile drives both the Portal's `hostName` and the target's `ready`, so
 * the reparenting shares one native transaction with the landing that reveals
 * the target; on the way back, the run home starts in a reaction to the same
 * value, in the frame the photo moves back into the host it lifts.
 */
type Mode = Readonly<{ teleport: boolean }>;

const RUN = {
  type: 'timing',
  duration: GALLERY_DURATION_MS,
  controlPoints: HERO_EASE_IN_OUT_QUAD,
} as const;
/** After the run's end (it started before `open`), the photo moves over. */
const TELEPORT_AFTER_MS = GALLERY_DURATION_MS + 80;

function flightTag(teleport: boolean, index: number): string {
  return `gallery-flight${teleport ? '-teleport' : ''}-${index}`;
}

function portalHostName(index: number): string {
  return `gallery-flight-detail-${index}`;
}

/** What the detail needs to fly a tile home: its controller and rest frame. */
type GalleryFlight = Readonly<{
  clip: SmoothClipController;
  rest: SmoothClipPresentation;
}>;
const flights = new Map<string, GalleryFlight>();

/**
 * Where each tile's live photo is (teleport variant): 0 in its flight host,
 * 1 teleported into the detail's target.
 */
const placements: SharedValue<number>[] = Array.from({ length: 12 }, () =>
  makeMutable(0)
);
/** Set by Back: the next move home also starts the run home. */
const leavings: SharedValue<boolean>[] = Array.from({ length: 12 }, () =>
  makeMutable(false)
);

const AnimatedPortal = Animated.createAnimatedComponent(Portal);
const AnimatedFlightTarget = Animated.createAnimatedComponent(
  SmoothClipFlightTarget
);

export function GalleryFlightLayout({ teleport }: Mode) {
  const stack = (
    <Stack
      screenOptions={{
        contentStyle: { backgroundColor: GALLERY_BACKGROUND },
        headerShown: false,
      }}
    >
      <Stack.Screen name="index" />
      {/* The detail fades in under the flying photo; the grid never moves. */}
      <Stack.Screen
        name="[id]"
        options={{ animation: 'fade', gestureEnabled: false }}
      />
    </Stack>
  );
  return teleport ? <PortalProvider>{stack}</PortalProvider> : stack;
}

export function GalleryFlightGrid({
  base,
  label,
  teleport,
}: Mode & { base: string; label: string }) {
  const router = useRouter();
  const open = useCallback(
    (index: number) => {
      router.push(`${base}/${index}` as never);
      scheduleGalleryMarkerClear();
    },
    [base, router]
  );
  return (
    <GalleryGridScreen
      label={label}
      onExit={() => router.back()}
      renderTile={({ index, photo, rect, layout }) => (
        <FlightTile
          index={index}
          key={photo.id}
          layout={layout}
          open={open}
          photo={photo}
          rect={rect}
          teleport={teleport}
        />
      )}
    />
  );
}

function FlightTile({
  index,
  layout,
  open,
  photo,
  rect,
  teleport,
}: Mode & {
  index: number;
  layout: GalleryLayout;
  open: (index: number) => void;
  photo: GalleryImage;
  rect: HeroRect;
}) {
  const { width, height } = useWindowDimensions();
  const rest = useMemo(
    () => galleryTilePresentation(rect, layout.detail, width, height),
    [height, layout.detail, rect, width]
  );
  // In window space: the detail's pixels wherever this screen sits.
  const detail = useMemo(
    () => ({
      ...galleryDetailPresentation(layout.detail),
      space: 'window' as const,
    }),
    [layout.detail]
  );
  const clip = useSmoothClipController(rest);
  const tag = flightTag(teleport, index);
  useEffect(() => {
    const flight = { clip, rest };
    flights.set(tag, flight);
    return () => {
      if (flights.get(tag) === flight) flights.delete(tag);
    };
  }, [clip, rest, tag]);
  const placement = placements[index]!;
  const tap = useMemo(
    () =>
      galleryTileTap(index, open, () => {
        'worklet';
        clip.ui.animateTo(detail, RUN);
        if (teleport) {
          // After the run's end: the target waits (`ready` false) until then.
          placement.set(
            withDelay(TELEPORT_AFTER_MS, withTiming(1, { duration: 0 }))
          );
        }
      }),
    [clip, detail, index, open, placement, teleport]
  );
  const hostName = portalHostName(index);
  const portalProps = useAnimatedProps(() => ({
    hostName: placement.get() >= 1 ? hostName : '',
  }));
  return (
    <>
      <GestureDetector gesture={tap}>
        <View style={rectStyle(rect)} testID={`gallery-tile-${index}`} />
      </GestureDetector>
      <SmoothClipView
        controller={clip}
        flight={tag}
        pointerEvents="none"
        style={StyleSheet.absoluteFill}
      >
        <View style={rectStyle(layout.detail)}>
          {teleport ? (
            <AnimatedPortal
              animatedProps={portalProps}
              name={`gallery-flight-photo-${index}`}
              style={galleryStyles.fill}
            >
              <GalleryPhoto photo={photo} />
            </AnimatedPortal>
          ) : (
            <GalleryPhoto photo={photo} />
          )}
        </View>
      </SmoothClipView>
    </>
  );
}

/**
 * The detail: the tile is already flying when this mounts, so its target
 * mounts hidden and is revealed in the frame the flight lands. Back flies the
 * tile home with a run that starts from the frame it landed on (the way back),
 * on the UI thread before the pop, as in the hero bench.
 */
export function GalleryFlightDetail({
  index,
  label,
  photo,
  teleport,
}: Mode & { index: number; label: string; photo: GalleryImage }) {
  const router = useRouter();
  const { detail } = useGalleryLayout();
  const tag = flightTag(teleport, index);
  const placement = placements[index]!;
  const leaving = leavings[index]!;
  // Published by the tile before this route mounts.
  const flight = flights.get(tag);

  // Teleport: the run home starts in the frame the photo moves back into the
  // host (the props of that frame are flushed after this reaction runs).
  useAnimatedReaction(
    () => placement.get(),
    (now, before) => {
      if (!leaving.get() || before === null || now >= before) return;
      leaving.set(false);
      if (!flight) {
        scheduleOnRN(router.back);
        return;
      }
      flight.clip.ui.animateTo(flight.rest, RUN);
      scheduleOnRN(router.back);
    }
  );
  // A detail popped some other way leaves the photo with its tile.
  useEffect(() => () => placement.set(0), [placement]);
  const targetProps = useAnimatedProps(() => ({
    ready: placement.get() >= 1,
  }));

  const back = useCallback(() => {
    if (teleport) {
      scheduleOnUI(() => {
        'worklet';
        leaving.set(true);
        placement.set(0);
      });
      return;
    }
    if (!flight) {
      router.back();
      return;
    }
    scheduleOnUI(() => {
      'worklet';
      flight.clip.ui.animateTo(flight.rest, RUN);
      scheduleOnRN(router.back);
    });
  }, [flight, leaving, placement, router, teleport]);

  return (
    <GalleryDetailScreen label={label} onBack={back}>
      {teleport ? (
        <AnimatedFlightTarget
          animatedProps={targetProps}
          ready={false}
          style={rectStyle(detail)}
          tag={tag}
        >
          <PortalHost name={portalHostName(index)} style={galleryStyles.fill} />
        </AnimatedFlightTarget>
      ) : (
        <SmoothClipFlightTarget style={rectStyle(detail)} tag={tag}>
          <GalleryPhoto photo={photo} />
        </SmoothClipFlightTarget>
      )}
    </GalleryDetailScreen>
  );
}
