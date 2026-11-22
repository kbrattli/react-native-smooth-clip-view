import { Image } from 'expo-image';
import type { ComponentProps } from 'react';
import { StyleSheet } from 'react-native';
import Animated, { SharedTransition } from 'react-native-reanimated';
import type { GalleryImage } from '../galleryImages';
import { GALLERY_DURATION_MS, galleryStyles } from './GalleryBench';
import { GALLERY_RADIUS } from './galleryBenchGeometry';

const AnimatedImage = Animated.createAnimatedComponent(Image);

/** SET's default run is `withTiming` with ease-in-out-quad: only the length is set. */
const GALLERY_SET_TRANSITION = SharedTransition.duration(GALLERY_DURATION_MS);

/**
 * A gallery photo as a Reanimated shared element: the same expo-image view
 * and props as `GalleryPhoto`, animated, with the tile's tag. As SET is
 * usually used, the image itself is the shared view: SET animates its frame
 * (so expo-image re-fits it every frame) and its corner radius, which is the
 * gallery radius on both ends.
 */
export function GallerySetPhoto({
  index,
  photo,
  style,
}: {
  index: number;
  photo: GalleryImage;
  style?: ComponentProps<typeof AnimatedImage>['style'];
}) {
  return (
    <AnimatedImage
      accessibilityLabel={photo.accessibilityLabel}
      contentFit="cover"
      sharedTransitionStyle={GALLERY_SET_TRANSITION}
      sharedTransitionTag={`gallery-set-${index}`}
      source={photo.source}
      style={[style ?? galleryStyles.fill, styles.rounded]}
      transition={null}
    />
  );
}

const styles = StyleSheet.create({
  rounded: { borderRadius: GALLERY_RADIUS },
});
