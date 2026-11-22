import { useLocalSearchParams } from 'expo-router';
import { galleryPhoto } from '../../galleryBench/galleryBenchPhotos';
import { GallerySetTeleportDetail } from '../../galleryBench/gallerySetTeleport';

export default function Detail() {
  const { index } = galleryPhoto(useLocalSearchParams().id);
  return (
    <GallerySetTeleportDetail
      index={index}
      label="Reanimated shared transition, with teleport"
    />
  );
}
