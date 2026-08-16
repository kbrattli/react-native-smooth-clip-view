import { useRouter } from 'expo-router';
import { useCallback } from 'react';
import { StyleSheet } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { GalleryGrid } from '../components/GalleryGrid';
import { GALLERY_IMAGES } from '../galleryImages';
import { useSharedElementTransition } from '../SharedElementTransitionContext';
import type { Rect } from '../zoomCities';

export default function ImageGalleryScreen() {
  const router = useRouter();
  const {
    activeIndex,
    hiddenIndex,
    measureItem,
    openItem,
    originRect,
    registerItemRef,
  } = useSharedElementTransition();

  const onItemMeasured = useCallback(
    (payload: { index: number; rect: Rect }) => {
      openItem(payload.index, payload.rect);
      router.push('/image-gallery-overlay');
    },
    [openItem, router]
  );

  return (
    <SafeAreaView edges={['bottom']} style={styles.root}>
      <GalleryGrid
        activeIndex={activeIndex}
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
