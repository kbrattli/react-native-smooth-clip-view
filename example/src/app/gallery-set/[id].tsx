import { useIsFocused, useLocalSearchParams, useRouter } from 'expo-router';
import { SharedTransitionBoundary } from 'react-native-reanimated';
import {
  GalleryDetailScreen,
  useGalleryLayout,
} from '../../galleryBench/GalleryBench';
import { rectStyle } from '../../galleryBench/galleryBenchGeometry';
import { galleryPhoto } from '../../galleryBench/galleryBenchPhotos';
import { GallerySetPhoto } from '../../galleryBench/gallerySet';

/**
 * The shared element's destination. This screen's boundary becomes the
 * topmost active one in the commit that mounts it, which starts the
 * transition from the tile's on-screen frame.
 */
export default function GallerySetDetail() {
  const router = useRouter();
  const isFocused = useIsFocused();
  const { index, photo } = galleryPhoto(useLocalSearchParams().id);
  const { detail } = useGalleryLayout();
  return (
    <SharedTransitionBoundary isActive={isFocused}>
      <GalleryDetailScreen
        label="Reanimated shared transition"
        onBack={() => router.back()}
      >
        <GallerySetPhoto
          index={index}
          photo={photo}
          style={rectStyle(detail)}
        />
      </GalleryDetailScreen>
    </SharedTransitionBoundary>
  );
}
