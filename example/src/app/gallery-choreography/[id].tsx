import { useLocalSearchParams, useRouter } from 'expo-router';
import {
  ChoreographyScreen,
  useChoreographyRouter,
} from 'react-native-screen-choreography/expo-router';
import {
  GalleryDetailScreen,
  useGalleryLayout,
} from '../../galleryBench/GalleryBench';
import {
  galleryRounded,
  rectStyle,
} from '../../galleryBench/galleryBenchGeometry';
import { galleryChoreography } from '../../galleryBench/galleryChoreography';

/**
 * The detail declares an empty, measured target; the grid's live photo moves
 * into it. The screen is opaque, as in the library's own gallery example.
 */
export default function GalleryChoreographyDetail() {
  const router = useRouter();
  const { back } = useChoreographyRouter(router);
  // The target receives its group from the forward navigation (`fromSource`).
  useLocalSearchParams();
  const { detail } = useGalleryLayout();
  return (
    <ChoreographyScreen>
      <GalleryDetailScreen
        label="react-native-screen-choreography"
        onBack={() => {
          back().catch(() => undefined);
        }}
      >
        <galleryChoreography.Element.Target
          fromSource
          name="photo"
          style={[rectStyle(detail), galleryRounded]}
        />
      </GalleryDetailScreen>
    </ChoreographyScreen>
  );
}
