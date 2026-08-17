import { useCallback } from 'react';
import { GALLERY_IMAGES } from '../galleryImages';
import { useSharedElementTransition } from '../SharedElementTransitionContext';
import { GalleryOverlay } from './GalleryOverlay';

/**
 * Gallery overlay host, rendered as a sibling after the navigator inside
 * SharedElementTransitionProvider. Mounting into the already-composited root
 * surface (instead of pushing a transparent modal route) puts the overlay's
 * first commit on screen at the next vsync — the modal's multi-frame
 * presentation latency, and the ready-gate that padded it, no longer exist.
 */
export function GalleryOverlayHost() {
  const {
    closeGallery,
    galleryState,
    hiddenIndex,
    measureItem,
    originIndex,
    originRect,
    setGalleryActiveIndex,
  } = useSharedElementTransition();

  // Pager settled on a different image: follow with the grid and re-measure
  // so a later close lands on the tile the user paged to.
  const onIndexChange = useCallback(
    (index: number) => {
      const image = GALLERY_IMAGES[index];
      if (!image) return;
      setGalleryActiveIndex(index);
      measureItem(image.id, index);
    },
    [measureItem, setGalleryActiveIndex]
  );

  if (!galleryState) return null;

  return (
    <GalleryOverlay
      hiddenIndex={hiddenIndex}
      initialOriginRect={galleryState.openRect}
      onClosed={closeGallery}
      onIndexChange={onIndexChange}
      openIndex={galleryState.openIndex}
      originIndex={originIndex}
      originRect={originRect}
      thumbRef={galleryState.thumbRef}
    />
  );
}
