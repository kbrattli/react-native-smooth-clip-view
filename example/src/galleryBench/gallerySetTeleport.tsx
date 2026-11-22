import { Stack, useIsFocused, useRouter } from 'expo-router';
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
} from 'react';
import { StyleSheet, View } from 'react-native';
import { GestureDetector } from 'react-native-gesture-handler';
import Animated, {
  SharedTransition,
  SharedTransitionBoundary,
} from 'react-native-reanimated';
import { Portal, PortalHost, PortalProvider } from 'react-native-teleport';
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
  galleryRounded,
  rectStyle,
} from './galleryBenchGeometry';

/**
 * NOT MEASURED: this wiring breaks the transition (docs/gallery-mount-time.md,
 * "Reanimated SET with teleport"). SET flies the detail's tagged view without
 * the teleported photo: the tile empties when the detail mounts and the photo
 * appears only when the run has ended. Kept to show why the bench has no
 * SET + teleport row.
 *
 * Reanimated shared element transitions with react-native-teleport added by
 * hand (Reanimated has no teleport mode), as for the SmoothClipView variant:
 * the detail renders no photo of its own. Both ends are an `Animated.View`
 * with the tile's `sharedTransitionTag`; the detail's holds a `PortalHost`,
 * and the tile's live photo is teleported into it in the commit that mounts
 * the detail (the open request and the Portal's `hostName` are one React
 * update), so SET animates the detail's view with the tile's own photo in it.
 * When the detail unmounts after its close, the photo returns to the tile.
 */
const SET_TRANSITION = SharedTransition.duration(GALLERY_DURATION_MS);

type Placement = Readonly<{
  inDetail: number | null;
  setInDetail: (index: number | null) => void;
}>;
const PlacementContext = createContext<Placement>({
  inDetail: null,
  setInDetail: () => {},
});

function hostName(index: number): string {
  return `gallery-set-detail-${index}`;
}

export function GallerySetTeleportLayout() {
  const [inDetail, setInDetail] = useState<number | null>(null);
  const placement = useMemo(() => ({ inDetail, setInDetail }), [inDetail]);
  return (
    <PortalProvider>
      <PlacementContext.Provider value={placement}>
        <Stack
          screenOptions={{
            contentStyle: { backgroundColor: GALLERY_BACKGROUND },
            headerShown: false,
          }}
        >
          <Stack.Screen name="index" />
          <Stack.Screen
            name="[id]"
            options={{ animation: 'fade', gestureEnabled: false }}
          />
        </Stack>
      </PlacementContext.Provider>
    </PortalProvider>
  );
}

export function GallerySetTeleportGrid({
  base,
  label,
}: {
  base: string;
  label: string;
}) {
  const router = useRouter();
  const isFocused = useIsFocused();
  const { inDetail, setInDetail } = useContext(PlacementContext);
  const open = useCallback(
    (index: number) => {
      // One React update: the detail mounts with the photo already in it.
      setInDetail(index);
      router.push(`${base}/${index}` as never);
      scheduleGalleryMarkerClear();
    },
    [base, router, setInDetail]
  );
  return (
    <SharedTransitionBoundary isActive={isFocused}>
      <GalleryGridScreen
        label={label}
        onExit={() => router.back()}
        renderTile={({ index, photo, rect }) => (
          <Tile
            inDetail={inDetail === index}
            index={index}
            key={photo.id}
            open={open}
            photo={photo}
            rect={rect}
          />
        )}
      />
    </SharedTransitionBoundary>
  );
}

function Tile({
  inDetail,
  index,
  open,
  photo,
  rect,
}: {
  inDetail: boolean;
  index: number;
  open: (index: number) => void;
  photo: GalleryImage;
  rect: HeroRect;
}) {
  const tap = useMemo(() => galleryTileTap(index, open), [index, open]);
  return (
    <GestureDetector gesture={tap}>
      <View style={rectStyle(rect)} testID={`gallery-tile-${index}`}>
        <Animated.View
          sharedTransitionStyle={SET_TRANSITION}
          sharedTransitionTag={`gallery-set-tp-${index}`}
          style={styles.frame}
        >
          <Portal
            hostName={inDetail ? hostName(index) : undefined}
            name={`gallery-set-photo-${index}`}
            style={galleryStyles.fill}
          >
            <GalleryPhoto photo={photo} />
          </Portal>
        </Animated.View>
      </View>
    </GestureDetector>
  );
}

export function GallerySetTeleportDetail({
  index,
  label,
}: {
  index: number;
  label: string;
}) {
  const router = useRouter();
  const isFocused = useIsFocused();
  const { detail } = useGalleryLayout();
  const { setInDetail } = useContext(PlacementContext);
  // The photo comes back to its tile once this route (and its host) is gone.
  useEffect(() => () => setInDetail(null), [setInDetail]);
  return (
    <SharedTransitionBoundary isActive={isFocused}>
      <GalleryDetailScreen label={label} onBack={() => router.back()}>
        <Animated.View
          sharedTransitionStyle={SET_TRANSITION}
          sharedTransitionTag={`gallery-set-tp-${index}`}
          style={[rectStyle(detail), styles.clip]}
        >
          <PortalHost name={hostName(index)} style={StyleSheet.absoluteFill} />
        </Animated.View>
      </GalleryDetailScreen>
    </SharedTransitionBoundary>
  );
}

const styles = StyleSheet.create({
  clip: galleryRounded,
  frame: { ...galleryRounded, height: '100%', width: '100%' },
});
