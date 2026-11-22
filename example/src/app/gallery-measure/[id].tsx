import { useLocalSearchParams } from 'expo-router';
import { galleryPhoto } from '../../galleryBench/galleryBenchPhotos';
import { GalleryMeasureDetail } from '../../galleryBench/galleryMeasure';

export default function Detail() {
  const { index, photo } = galleryPhoto(useLocalSearchParams().id);
  return (
    <GalleryMeasureDetail
      index={index}
      label="Reanimated measure(), without teleport"
      photo={photo}
      teleport={false}
    />
  );
}
