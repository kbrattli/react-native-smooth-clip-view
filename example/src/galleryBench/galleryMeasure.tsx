import { Stack, useRouter } from 'expo-router';
import { useCallback, useEffect, useLayoutEffect, useMemo } from 'react';
import { Platform, StyleSheet, View } from 'react-native';
import { GestureDetector } from 'react-native-gesture-handler';
import Animated, {
  Easing,
  makeMutable,
  measure,
  useAnimatedProps,
  useAnimatedReaction,
  useAnimatedRef,
  useAnimatedStyle,
  useDerivedValue,
  useSharedValue,
  withTiming,
  type SharedValue,
} from 'react-native-reanimated';
import { useReanimatedTransitionProgress } from 'react-native-screens/reanimated';
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
import {
  GALLERY_BACKGROUND,
  galleryPhotoFrame,
  galleryRounded,
  rectStyle,
} from './galleryBenchGeometry';
import {
  GALLERY_MARKS,
  markGalleryJS,
  markGalleryLoad,
  markGalleryUI,
} from './galleryMarks';
import { GALLERY_BENCH_EASING, isGalleryStartBench } from './galleryStartBench';

/**
 * The do-it-yourself hero (docs/gallery-mount-time.md): plain Reanimated, no
 * transition library. The tile's UI-thread tap calls `measure()` on the
 * tile's animated ref and keeps its window rect in a shared value; the detail
 * starts a `withTiming` run (500 ms, ease-in-out-quad) when it is on screen
 * (react-native-screens' transition progress, on the UI thread). The run
 * animates a rounded clip (absolute, `overflow: 'hidden'`, the gallery
 * radius) by its left / top / width / height from that rect to
 * the detail rect, so its corners keep their radius. Inside it the photo is
 * laid out once at the detail rect's size and only scaled by a transform to
 * cover the clip (`galleryPhotoFrame`): the photo never changes size, so
 * expo-image never re-fits it. Its backdrop fades in with the same progress.
 * Back runs it in reverse and pops when it ends.
 *
 * The tile is a rounded clip at the tile rect. Without teleport it shows a
 * plain tile-sized photo, as a grid would; the detail's copy starts as the
 * same crop. With teleport it holds the photo that moves: laid out at the
 * detail rect's size and scaled down to cover the tile, so it never resizes.
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
 * the whole run. Hiding it from the mount effect left it empty before the
 * copy showed (9 of 10 Release openings): the hide reached the UI thread
 * before the copy's mount.
 *
 * With teleport (react-native-teleport added by hand), the detail renders no
 * photo: its container mounts empty over the tile, and once the detail is on
 * screen, just before the run's first frame, the tile's live photo moves into
 * it, through the Portal's `hostName`, set from the UI thread as the flight +
 * teleport variant does. Its host sits in the scaled, detail-sized frame, so
 * it never resizes either (a resizing host sizes a teleported photo a frame
 * late: docs/gallery-mount-time.md).
 * Back moves the photo back when the run home ends, with the container on the
 * tile.
 */
type Mode = Readonly<{ teleport: boolean }>;

const TIMING = {
  duration: GALLERY_DURATION_MS,
  easing: Easing.inOut(Easing.quad),
};
/** The start-latency bench's run (galleryStartBench.ts). */
const TIMING_BENCH = { ...TIMING, easing: GALLERY_BENCH_EASING };

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

/** A screen is on screen at its will-appear event on Android, not on iOS. */
const SHOWN_AT_WILL_APPEAR = Platform.OS === 'android';

function onLanded(finished?: boolean) {
  'worklet';
  if (finished) markGalleryUI('landed');
}

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
      markGalleryJS('open');
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
        <MeasureTile
          detail={layout.detail}
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
  detail,
  index,
  open,
  photo,
  rect,
  teleport,
}: Mode & {
  detail: HeroRect;
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
  const photoFrame = useMemo(
    () => galleryPhotoFrame(rect, detail),
    [detail, rect]
  );
  return (
    <GestureDetector gesture={tap}>
      <Animated.View
        ref={ref}
        style={[rectStyle(rect), galleryRounded]}
        testID={`gallery-tile-${index}`}
      >
        {teleport ? (
          // The photo that teleports: laid out at the detail rect's size and
          // scaled down to the tile, so it never resizes.
          <View style={photoFrame}>
            <AnimatedPortal
              animatedProps={portalProps}
              name={`gallery-measure-photo-${index}`}
              style={galleryStyles.fill}
            >
              <GalleryPhoto
                onLoad={
                  GALLERY_MARKS
                    ? (e) => markGalleryLoad(e.cacheType)
                    : undefined
                }
                photo={photo}
              />
            </AnimatedPortal>
          </View>
        ) : (
          // A plain grid photo; the detail renders its own copy.
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
  // The bench's curve, or the start-latency bench's (choreography's).
  const timing = isGalleryStartBench() ? TIMING_BENCH : TIMING;
  markGalleryJS('render', teleport ? 'measure-tp' : 'measure');
  useLayoutEffect(() => markGalleryJS('layoutEffect'), []);

  useEffect(() => markGalleryJS('effect'), []);
  // The run starts when this screen is on screen, which react-native-screens
  // reports on the UI thread through its transition events. It shows a new
  // screen a frame or two after its mount, so a run started from the mount
  // effect ran unseen until then (its first visible frame was a fifth of the
  // way in), and with teleport the photo could leave the tile for a host not
  // yet on screen: the tile showed empty for a frame
  // (docs/gallery-mount-time.md).
  // - Android: will-appear (progress 0, going forward), sent when the screen's
  //   (empty) animation starts, after its first draw. Its appear event comes
  //   only when that animation ends, about two frames later.
  // - iOS: appear (progress 1, from `viewDidAppear`), 2–3 ms after
  //   will-appear, which comes before the view is in the window.
  // Appear also starts it on Android if will-appear never came.
  //
  // Teleport: the tile hands its photo over in the same reaction, before the
  // run's first frame. The clip still sits on the tile then, so the photo
  // shows where it was, and the first frame moves it.
  const screen = useReanimatedTransitionProgress();
  useAnimatedReaction(
    () =>
      screen.closing.get() === 0 &&
      (screen.progress.get() >= 1 ||
        (SHOWN_AT_WILL_APPEAR && screen.goingForward.get() === 1)),
    (shown, wasShown) => {
      if (!shown || wasShown || progress.get() > 0) return;
      markGalleryUI('shown');
      if (teleport && opened.get() !== index) {
        markGalleryUI('handover');
        opened.set(index);
      }
      progress.set(withTiming(1, timing, GALLERY_MARKS ? onLanded : undefined));
    }
  );
  useAnimatedReaction(
    () => progress.get() > 0,
    (started) => {
      if (started) markGalleryUI('frame1');
    }
  );
  // Diagnostics (GALLERY_MARKS): the screen's will-appear event (progress 0,
  // going forward) and its appear event (progress 1).
  useAnimatedReaction(
    () =>
      screen.closing.get() === 0
        ? `${screen.progress.get()}/${screen.goingForward.get()}`
        : 'closing',
    (event) => markGalleryUI(`screen:${event}`)
  );
  // A detail popped some other way gives the tile back its photo.
  useEffect(() => () => opened.set(-1), [opened]);

  // The clip's rect at the run's progress: it animates left / top / width /
  // height; the photo inside only follows with its cover transform.
  const clip = useDerivedValue(() => {
    const from = measured.get() ?? detail;
    const p = progress.get();
    return {
      x: from.x + (detail.x - from.x) * p,
      y: from.y + (detail.y - from.y) * p,
      width: from.width + (detail.width - from.width) * p,
      height: from.height + (detail.height - from.height) * p,
    };
  });
  const frame = useAnimatedStyle(() => {
    const rect = clip.get();
    return {
      left: rect.x,
      top: rect.y,
      width: rect.width,
      height: rect.height,
    };
  });
  // The photo's size is fixed (the detail rect's); only its transform runs.
  const photoSize = useMemo(
    () => ({
      height: detail.height,
      left: 0,
      position: 'absolute' as const,
      top: 0,
      width: detail.width,
    }),
    [detail]
  );
  const photoTransform = useAnimatedStyle(() => ({
    transform: galleryPhotoFrame(clip.get(), detail).transform,
  }));
  const backdrop = useAnimatedStyle(() => ({ opacity: progress.get() }));

  const back = useCallback(() => {
    progress.set(
      withTiming(0, timing, (finished) => {
        'worklet';
        if (!finished) return;
        // The container sits on the tile now: with teleport the tile takes
        // its photo back, then the detail pops.
        opened.set(-1);
        scheduleOnRN(router.back);
      })
    );
  }, [opened, progress, router, timing]);

  return (
    <GalleryDetailScreen label={label} onBack={back} transparent>
      <Animated.View
        pointerEvents="none"
        style={[StyleSheet.absoluteFill, styles.backdrop, backdrop]}
      />
      <Animated.View style={[styles.frame, frame]}>
        <Animated.View style={[photoSize, photoTransform]}>
          {teleport ? (
            <PortalHost
              name={hostName(index)}
              style={StyleSheet.absoluteFill}
            />
          ) : (
            <GalleryPhoto
              onLoad={
                GALLERY_MARKS ? (e) => markGalleryLoad(e.cacheType) : undefined
              }
              photo={photo}
            />
          )}
        </Animated.View>
      </Animated.View>
    </GalleryDetailScreen>
  );
}

const styles = StyleSheet.create({
  backdrop: { backgroundColor: GALLERY_BACKGROUND },
  frame: { ...galleryRounded, position: 'absolute' },
});
