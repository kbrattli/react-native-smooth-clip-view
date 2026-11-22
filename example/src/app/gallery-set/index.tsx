import { useIsFocused, useRouter } from 'expo-router';
import { useCallback, useMemo } from 'react';
import { View } from 'react-native';
import { GestureDetector } from 'react-native-gesture-handler';
import { SharedTransitionBoundary } from 'react-native-reanimated';
import {
  GalleryGridScreen,
  galleryTileTap,
  scheduleGalleryMarkerClear,
} from '../../galleryBench/GalleryBench';
import { rectStyle } from '../../galleryBench/galleryBenchGeometry';
import { GallerySetPhoto } from '../../galleryBench/gallerySet';
import type { GalleryImage } from '../../galleryImages';
import type { HeroRect } from '../../heroBench/heroBenchGeometry';

/**
 * The grid with Reanimated 4.8 shared element transitions: each tile is an
 * animated expo-image with its own `sharedTransitionTag`. The transition
 * starts in the mount of the navigation commit that the tap requests.
 */
export default function GallerySetGrid() {
  const router = useRouter();
  const isFocused = useIsFocused();
  const open = useCallback(
    (index: number) => {
      router.push(`/gallery-set/${index}`);
      scheduleGalleryMarkerClear();
    },
    [router]
  );
  return (
    <SharedTransitionBoundary isActive={isFocused}>
      <GalleryGridScreen
        label="Reanimated shared transition"
        onExit={() => router.back()}
        renderTile={({ index, photo, rect }) => (
          <SetTile
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

function SetTile({
  index,
  open,
  photo,
  rect,
}: {
  index: number;
  open: (index: number) => void;
  photo: GalleryImage;
  rect: HeroRect;
}) {
  const tap = useMemo(() => galleryTileTap(index, open), [index, open]);
  return (
    <GestureDetector gesture={tap}>
      <View style={rectStyle(rect)} testID={`gallery-tile-${index}`}>
        <GallerySetPhoto index={index} photo={photo} />
      </View>
    </GestureDetector>
  );
}
