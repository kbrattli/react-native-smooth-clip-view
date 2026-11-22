import { Stack, useRouter } from 'expo-router';
import { useCallback, useEffect, useMemo } from 'react';
import { StyleSheet } from 'react-native';
import { GestureDetector } from 'react-native-gesture-handler';
import Animated, {
  Easing,
  makeMutable,
  measure,
  useAnimatedProps,
  useAnimatedReaction,
  useAnimatedRef,
  useAnimatedStyle,
  useSharedValue,
  withTiming,
  type SharedValue,
} from 'react-native-reanimated';
import { Portal, PortalHost, PortalProvider } from 'react-native-teleport';
import { scheduleOnRN } from 'react-native-worklets';
import type { GalleryImage } from '../galleryImages';
import type { HeroRect } from '../heroBench/heroBenchGeometry';
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
import { GALLERY_BACKGROUND, rectStyle } from './galleryBenchGeometry';

/**
 * The do-it-yourself hero (docs/gallery-mount-time.md): plain Reanimated, no
 * transition library. The tile's UI-thread tap calls `measure()` on the
 * tile's animated ref and keeps its window rect in a shared value; the detail
 * starts a `withTiming` run (500 ms, ease-in-out-quad) on mount, in an
 * effect, that animates its photo container's left / top / width / height
 * from that rect to the detail rect, so expo-image re-fits the photo every
 * frame. Its backdrop fades in with the same progress. Back runs it in
 * reverse and pops when it ends.
 *
 * The detail is a transparent modal without a native animation, as such
 * heroes usually are: the grid must stay visible under it, and a natively
 * animated screen would fade (or slide) the photo with it. It is the
 * contained kind (react-native-screens mounts it in the stack's own view, as
 * screen-transitions and choreography do); in a Debug check, a UIKit
 * `transparentModal` left the tile empty for a frame.
 *
 * Without teleport, the detail renders its own photo over the tile. The tile
 * is not hidden: the detail rect contains it, so the opaque copy covers it for
 * the whole run. Hiding it from the effect that starts the run left it empty
 * before the copy showed (9 of 10 Release openings): the hide reached the UI
 * thread before the copy's mount.
 *
 * With teleport (react-native-teleport added by hand), the detail renders no
 * photo: its container mounts empty over the tile, and the run's first frame
 * moves the tile's live photo into it, through the Portal's `hostName`, set
 * from the UI thread as the flight + teleport variant does.
 * Back moves the photo back when the run home ends, with the container on the
 * tile.
 */
type Mode = Readonly<{ teleport: boolean }>;

const TIMING = {
  duration: GALLERY_DURATION_MS,
  easing: Easing.inOut(Easing.quad),
};

type MeasureState = Readonly<{
  /** The opened tile's window rect, measured in the tap. */
  measured: SharedValue<HeroRect | null>;
  /** Teleport: the tile whose photo is in the detail, or -1. */
  opened: SharedValue<number>;
}>;
const states: Record<'plain' | 'teleport', MeasureState> = {
  plain: {
    measured: makeMutable<HeroRect | null>(null),
    opened: makeMutable(-1),
  },
  teleport: {
    measured: makeMutable<HeroRect | null>(null),
    opened: makeMutable(-1),
  },
};
const stateOf = (teleport: boolean) =>
  teleport ? states.teleport : states.plain;

function hostName(index: number): string {
  return `gallery-measure-detail-${index}`;
}

const AnimatedPortal = Animated.createAnimatedComponent(Portal);

export function GalleryMeasureLayout({ teleport }: Mode) {
  const stack = (
    <Stack
      screenOptions={{
        contentStyle: { backgroundColor: GALLERY_BACKGROUND },
        headerShown: false,
      }}
    >
      <Stack.Screen name="index" />
      {/* The grid stays under the detail, which animates itself. */}
      <Stack.Screen
        name="[id]"
        options={{
          animation: 'none',
          contentStyle: { backgroundColor: 'transparent' },
          gestureEnabled: false,
          presentation: 'containedTransparentModal',
        }}
      />
    </Stack>
  );
  return teleport ? <PortalProvider>{stack}</PortalProvider> : stack;
}

export function GalleryMeasureGrid({
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
      renderTile={({ index, photo, rect }) => (
        <MeasureTile
          index={index}
          key={photo.id}
          open={open}
          photo={photo}
          rect={rect}
          teleport={teleport}
        />
      )}
    />
  );
}

function MeasureTile({
  index,
  open,
  photo,
  rect,
  teleport,
}: Mode & {
  index: number;
  open: (index: number) => void;
  photo: GalleryImage;
  rect: HeroRect;
}) {
  const ref = useAnimatedRef<Animated.View>();
  const { measured, opened } = stateOf(teleport);
  const tap = useMemo(
    () =>
      galleryTileTap(index, open, () => {
        'worklet';
        const m = measure(ref);
        if (m) {
          measured.set({
            x: m.pageX,
            y: m.pageY,
            width: m.width,
            height: m.height,
          });
        }
      }),
    [index, measured, open, ref]
  );
  const host = hostName(index);
  const portalProps = useAnimatedProps(() => ({
    hostName: opened.get() === index ? host : '',
  }));
  return (
    <GestureDetector gesture={tap}>
      <Animated.View
        ref={ref}
        style={[rectStyle(rect), styles.clip]}
        testID={`gallery-tile-${index}`}
      >
        {teleport ? (
          <AnimatedPortal
            animatedProps={portalProps}
            name={`gallery-measure-photo-${index}`}
            style={galleryStyles.fill}
          >
            <GalleryPhoto photo={photo} />
          </AnimatedPortal>
        ) : (
          <GalleryPhoto photo={photo} />
        )}
      </Animated.View>
    </GestureDetector>
  );
}

export function GalleryMeasureDetail({
  index,
  label,
  photo,
  teleport,
}: Mode & { index: number; label: string; photo: GalleryImage }) {
  const router = useRouter();
  const { detail } = useGalleryLayout();
  const { measured, opened } = stateOf(teleport);
  const progress = useSharedValue(0);

  // The run starts on mount, as such heroes usually start it.
  useEffect(() => {
    progress.set(withTiming(1, TIMING));
  }, [progress]);
  // Teleport: the tile hands its photo over in the run's first frame. From
  // the mount effect it could move before this screen was on screen.
  useAnimatedReaction(
    () => progress.get() > 0,
    (started, wasStarted) => {
      if (teleport && started && !wasStarted && opened.get() !== index) {
        opened.set(index);
      }
    }
  );
  // A detail popped some other way gives the tile back its photo.
  useEffect(() => () => opened.set(-1), [opened]);

  const frame = useAnimatedStyle(() => {
    const from = measured.get() ?? detail;
    const p = progress.get();
    return {
      left: from.x + (detail.x - from.x) * p,
      top: from.y + (detail.y - from.y) * p,
      width: from.width + (detail.width - from.width) * p,
      height: from.height + (detail.height - from.height) * p,
    };
  });
  const backdrop = useAnimatedStyle(() => ({ opacity: progress.get() }));

  const back = useCallback(() => {
    progress.set(
      withTiming(0, TIMING, (finished) => {
        'worklet';
        if (!finished) return;
        // The container sits on the tile now: with teleport the tile takes
        // its photo back, then the detail pops.
        opened.set(-1);
        scheduleOnRN(router.back);
      })
    );
  }, [opened, progress, router]);

  return (
    <GalleryDetailScreen label={label} onBack={back} transparent>
      <Animated.View
        pointerEvents="none"
        style={[StyleSheet.absoluteFill, styles.backdrop, backdrop]}
      />
      <Animated.View style={[styles.frame, frame]}>
        {teleport ? (
          <PortalHost name={hostName(index)} style={StyleSheet.absoluteFill} />
        ) : (
          <GalleryPhoto photo={photo} />
        )}
      </Animated.View>
    </GalleryDetailScreen>
  );
}

const styles = StyleSheet.create({
  backdrop: { backgroundColor: GALLERY_BACKGROUND },
  clip: { overflow: 'hidden' },
  frame: { overflow: 'hidden', position: 'absolute' },
});
