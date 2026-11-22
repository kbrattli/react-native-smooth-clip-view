import { useLocalSearchParams } from 'expo-router';
import { galleryPhoto } from '../../galleryBench/galleryBenchPhotos';
import { GalleryFlightDetail } from '../../galleryBench/galleryFlights';

export default function Detail() {
  const { index, photo } = galleryPhoto(useLocalSearchParams().id);
  return (
    <GalleryFlightDetail
      index={index}
      label="SmoothClipView flight, with teleport"
      photo={photo}
      teleport={true}
    />
  );
}
