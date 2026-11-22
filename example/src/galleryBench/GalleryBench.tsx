import { Image, type ImageProps } from 'expo-image';
import { useEffect, useMemo, type ReactNode } from 'react';
import { StyleSheet, Text, useWindowDimensions, View } from 'react-native';
import { Gesture } from 'react-native-gesture-handler';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { scheduleOnRN } from 'react-native-worklets';
import {
  HeroBenchButton,
  HeroBenchControls,
  HeroBenchRow,
} from '../heroBench/HeroBenchChrome';
import type { HeroRect } from '../heroBench/heroBenchGeometry';
import {
  clearHeroBenchMarker,
  lightHeroBenchMarker,
} from '../heroBench/heroBenchProbe';
import type { GalleryImage } from '../galleryImages';
import {
  GALLERY_BACKGROUND,
  galleryLayout,
  publishGalleryLayout,
  type GalleryLayout,
} from './galleryBenchGeometry';
import { GALLERY_PHOTOS } from './galleryBenchPhotos';
import { markGalleryTap } from './galleryMarks';

/** Every variant's run: 500 ms, ease-in-out-quad where the library allows. */
export const GALLERY_DURATION_MS = 500;
/** The tap marker stays lit this long after the run's duration. */
const MARKER_TAIL_MS = 700;

export function useGalleryLayout(): GalleryLayout {
  const insets = useSafeAreaInsets();
  const { width, height } = useWindowDimensions();
  return useMemo(
    () => galleryLayout(width, height, insets.top),
    [height, insets.top, width]
  );
}

/**
 * The one tap every variant starts from: a UI-thread `Gesture.Tap` on the
 * tile. It lights the hero bench's tap marker in the touch-up's main-thread
 * turn, runs `start` (the flight's run; nothing for the others), then hands
 * the navigation to JS.
 */
export function galleryTileTap(
  index: number,
  open: (index: number) => void,
  start?: () => void
) {
  return Gesture.Tap().onEnd((_event, success) => {
    'worklet';
    if (!success) return;
    markGalleryTap();
    lightHeroBenchMarker();
    start?.();
    scheduleOnRN(open, index);
  });
}

/** Call from `open`, after the navigation request. */
export function scheduleGalleryMarkerClear() {
  setTimeout(clearHeroBenchMarker, GALLERY_DURATION_MS + MARKER_TAIL_MS);
}

/**
 * A gallery photo, decoded by expo-image the same way in every variant (and
 * on both ends of each transition).
 */
export function GalleryPhoto({
  photo,
  style,
  ...rest
}: { photo: GalleryImage } & Omit<ImageProps, 'source'>) {
  return (
    <Image
      accessibilityLabel={photo.accessibilityLabel}
      contentFit="cover"
      source={photo.source}
      style={style ?? styles.fill}
      transition={null}
      {...rest}
    />
  );
}

/**
 * The grid screen shared by every variant: twelve tiles at the layout's
 * rects (each variant renders its own tile), the variant's name and Exit in
 * the control bar. Publishes the layout for the frame analysis.
 */
export function GalleryGridScreen({
  label,
  renderTile,
  onExit,
  children,
}: {
  label: string;
  renderTile: (tile: {
    index: number;
    photo: GalleryImage;
    rect: HeroRect;
    layout: GalleryLayout;
  }) => ReactNode;
  onExit: () => void;
  children?: ReactNode;
}) {
  const layout = useGalleryLayout();
  const { width, height } = useWindowDimensions();
  useEffect(() => {
    publishGalleryLayout(layout, width, height);
  }, [height, layout, width]);
  return (
    <View style={styles.screen} testID="gallery-grid">
      {GALLERY_PHOTOS.map((photo, index) =>
        renderTile({ index, photo, rect: layout.tiles[index]!, layout })
      )}
      {children}
      <HeroBenchControls top={layout.controlsTop}>
        <Text style={styles.label}>{label}</Text>
        <HeroBenchRow>
          <HeroBenchButton
            label="Exit"
            onPress={onExit}
            testID="gallery-exit"
          />
        </HeroBenchRow>
      </HeroBenchControls>
    </View>
  );
}

/**
 * The detail screen's chrome: an opaque background, the variant's photo
 * (children, at the layout's detail rect) and Back.
 */
export function GalleryDetailScreen({
  label,
  onBack,
  children,
  transparent = false,
}: {
  label: string;
  onBack: () => void;
  children: ReactNode;
  /** The navigator paints the background (it fades it in). */
  transparent?: boolean;
}) {
  const layout = useGalleryLayout();
  return (
    <View
      style={transparent ? styles.transparent : styles.screen}
      testID="gallery-detail"
    >
      {children}
      <HeroBenchControls top={layout.controlsTop}>
        <Text style={styles.label}>{label}</Text>
        <HeroBenchRow>
          <HeroBenchButton
            label="Back"
            onPress={onBack}
            testID="gallery-back"
          />
        </HeroBenchRow>
      </HeroBenchControls>
    </View>
  );
}

export const galleryStyles = StyleSheet.create({
  fill: { height: '100%', width: '100%' },
  screen: { flex: 1, backgroundColor: GALLERY_BACKGROUND },
});

const styles = StyleSheet.create({
  fill: galleryStyles.fill,
  screen: galleryStyles.screen,
  transparent: { flex: 1 },
  label: { color: '#9FB0C7', fontSize: 12, fontWeight: '700' },
});
