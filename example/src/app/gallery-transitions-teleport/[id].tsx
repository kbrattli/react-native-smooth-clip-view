import { useLocalSearchParams } from 'expo-router';
import { galleryPhoto } from '../../galleryBench/galleryBenchPhotos';
import { ScreenTransitionsDetail } from '../../galleryBench/galleryScreenTransitions';

export default function Detail() {
  const { index, photo } = galleryPhoto(useLocalSearchParams().id);
  return (
    <ScreenTransitionsDetail
      index={index}
      label="react-native-screen-transitions, with teleport"
      photo={photo}
      teleport={true}
    />
  );
}
