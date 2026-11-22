import { Image } from 'expo-image';
import type { ComponentProps } from 'react';
import Animated, { SharedTransition } from 'react-native-reanimated';
import type { GalleryImage } from '../galleryImages';
import { GALLERY_DURATION_MS, galleryStyles } from './GalleryBench';

const AnimatedImage = Animated.createAnimatedComponent(Image);

/** SET's default run is `withTiming` with ease-in-out-quad: only the length is set. */
const GALLERY_SET_TRANSITION = SharedTransition.duration(GALLERY_DURATION_MS);

/**
 * A gallery photo as a Reanimated shared element: the same expo-image view
 * and props as `GalleryPhoto`, animated, with the tile's tag.
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
      style={style ?? galleryStyles.fill}
      transition={null}
    />
  );
}
