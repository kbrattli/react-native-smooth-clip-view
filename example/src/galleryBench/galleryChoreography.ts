import { defineTransition } from 'react-native-screen-choreography/expo-router';
import { GALLERY_DURATION_MS } from './GalleryBench';
import { GALLERY_RADIUS } from './galleryBenchGeometry';

/**
 * The gallery's choreography: one shared `bounds` element (the photo) and no
 * other motion. A `duration` selects the library's timing run, which is always
 * cubic ease-out (navigation options expose no easing); it is the closest it
 * has to the bench's 500 ms ease-in-out-quad. The gallery radius at both ends.
 */
export const galleryChoreography = defineTransition({
  motion: { duration: GALLERY_DURATION_MS },
  shared: {
    photo: { kind: 'bounds', radius: [GALLERY_RADIUS, GALLERY_RADIUS] },
  },
});

export function galleryChoreographyGroup(index: number): string {
  return `gallery.${index}`;
}
