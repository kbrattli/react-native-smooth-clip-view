import { useCallback } from 'react';
import { StyleSheet } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import {
  GalleryGrid,
  type GalleryMeasuredPayload,
} from '../components/GalleryGrid';
import { GALLERY_IMAGES } from '../galleryImages';
import { useSharedElementTransition } from '../SharedElementTransitionContext';

export default function ImageGalleryScreen() {
  const {
    galleryState,
    hiddenIndex,
    measureItem,
    openGalleryItem,
    originRect,
    registerItemRef,
  } = useSharedElementTransition();

  const onItemMeasured = useCallback(
    (payload: GalleryMeasuredPayload) =>
      openGalleryItem(payload.index, payload.rect, payload.thumbRef),
    [openGalleryItem]
  );

  return (
    <SafeAreaView edges={['bottom']} style={styles.root}>
      <GalleryGrid
        activeIndex={galleryState?.activeIndex ?? null}
        hiddenIndex={hiddenIndex}
        images={GALLERY_IMAGES}
        onActiveItemReady={measureItem}
        onItemMeasured={onItemMeasured}
        onRegisterRef={registerItemRef}
        originRect={originRect}
      />
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  root: { backgroundColor: '#000000', flex: 1 },
});
