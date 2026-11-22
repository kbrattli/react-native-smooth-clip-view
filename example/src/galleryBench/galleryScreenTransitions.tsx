import { useRouter } from 'expo-router';
import { useCallback, useEffect, useLayoutEffect, useMemo } from 'react';
import { StyleSheet, View } from 'react-native';
import { GestureDetector } from 'react-native-gesture-handler';
import { Easing, interpolate } from 'react-native-reanimated';
import Transition, {
  type ScreenInterpolationProps,
} from 'react-native-screen-transitions';
import { BlankStack } from 'react-native-screen-transitions/expo-router';
import type { GalleryImage } from '../galleryImages';
import type { HeroRect } from '../heroBench/heroBenchGeometry';
import {
  GALLERY_DURATION_MS,
  GalleryDetailScreen,
  GalleryGridScreen,
  GalleryPhoto,
  galleryTileTap,
  scheduleGalleryMarkerClear,
  useGalleryLayout,
} from './GalleryBench';
import {
  GALLERY_BACKGROUND,
  galleryRounded,
  rectStyle,
} from './galleryBenchGeometry';
import {
  GALLERY_MARKS,
  markGalleryJS,
  markGalleryLoad,
  markGalleryUI,
} from './galleryMarks';

/**
 * react-native-screen-transitions 4.2 (docs/gallery-mount-time.md): its Blank
 * Stack, the navigator its docs recommend for bounds transitions, nested in
 * the app's root native stack. Each tile is a `Transition.Boundary` (group
 * `gallery`, id = tile index) and the detail has the matching boundary. The
 * transition is the library's shared element ("Bounds Transitions"): the
 * detail's boundary is styled with `bounds().styles({ method: 'size' })`, so
 * the photo's frame moves and resizes from the tile to the detail rect and
 * expo-image re-fits it each frame, as Reanimated's SET does. The rest of
 * the detail fades in over the grid on the backdrop, like the other variants'
 * fade; the grid itself does not move.
 *
 * With teleport, both boundaries set `handoff`: the tile's live photo moves
 * into the detail's boundary through react-native-teleport instead of the
 * detail rendering its own copy. Without it, the tile is hidden while its
 * copy on the detail flies (as SET hides its source).
 */
type Mode = Readonly<{ teleport: boolean }>;

const GROUP = 'gallery';
const TIMING = {
  duration: GALLERY_DURATION_MS,
  easing: Easing.inOut(Easing.quad),
};

function routeId(props: ScreenInterpolationProps): string | undefined {
  'worklet';
  const params = (route: { params?: object } | undefined) =>
    route?.params as { id?: string } | undefined;
  return (
    params(props.active?.route)?.id ??
    params(props.next?.route)?.id ??
    params(props.current?.route)?.id
  );
}

function detailOptions({ teleport }: Mode) {
  return {
    gestureEnabled: false,
    // The bench's 500 ms ease-in-out-quad in place of the default spring.
    transitionSpec: { open: TIMING, close: TIMING },
    screenStyleInterpolator: (props: ScreenInterpolationProps) => {
      'worklet';
      const id = routeId(props);
      if (!id) return {};
      const tag = `${GROUP}:${id}`;
      if (props.focused) {
        if (GALLERY_MARKS && props.progress > 0) {
          markGalleryUI('frame1');
          if (props.progress >= 1) markGalleryUI('landed');
        }
        return {
          [tag]: {
            style: props
              .bounds({ id, group: GROUP })
              .styles({ method: 'size' }),
          },
          backdrop: {
            style: {
              backgroundColor: GALLERY_BACKGROUND,
              opacity: interpolate(props.progress, [0, 1], [0, 1], 'clamp'),
            },
          },
        };
      }
      // The grid under it: hide the tile while its copy flies.
      return teleport
        ? {}
        : { [tag]: { style: { opacity: props.active.settled ? 1 : 0 } } };
    },
  };
}

export function ScreenTransitionsLayout({ teleport }: Mode) {
  const options = useMemo(() => detailOptions({ teleport }), [teleport]);
  return (
    <BlankStack>
      <BlankStack.Screen name="index" />
      <BlankStack.Screen name="[id]" options={options} />
    </BlankStack>
  );
}

export function ScreenTransitionsGrid({
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
      renderTile={({ index, photo, rect }) => (
        <BoundaryTile
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

function BoundaryTile({
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
  const tap = useMemo(() => galleryTileTap(index, open), [index, open]);
  return (
    <GestureDetector gesture={tap}>
      <View style={rectStyle(rect)} testID={`gallery-tile-${index}`}>
        <Transition.Boundary
          group={GROUP}
          handoff={teleport}
          id={String(index)}
          style={[StyleSheet.absoluteFill, galleryRounded]}
        >
          <GalleryPhoto
            onLoad={
              GALLERY_MARKS && teleport
                ? (e) => markGalleryLoad(e.cacheType)
                : undefined
            }
            photo={photo}
          />
        </Transition.Boundary>
      </View>
    </GestureDetector>
  );
}

export function ScreenTransitionsDetail({
  index,
  label,
  photo,
  teleport,
}: Mode & { index: number; label: string; photo: GalleryImage }) {
  const router = useRouter();
  const { detail } = useGalleryLayout();
  markGalleryJS('render', teleport ? 'st-tp' : 'st');
  useLayoutEffect(() => markGalleryJS('layoutEffect'), []);
  useEffect(() => markGalleryJS('effect'), []);
  return (
    <GalleryDetailScreen label={label} onBack={() => router.back()} transparent>
      <Transition.Boundary
        group={GROUP}
        handoff={teleport}
        id={String(index)}
        style={[rectStyle(detail), galleryRounded]}
      >
        {/* With handoff, the tile's own photo arrives here. */}
        {teleport ? null : (
          <GalleryPhoto
            onLoad={
              GALLERY_MARKS ? (e) => markGalleryLoad(e.cacheType) : undefined
            }
            photo={photo}
          />
        )}
      </Transition.Boundary>
    </GalleryDetailScreen>
  );
}
