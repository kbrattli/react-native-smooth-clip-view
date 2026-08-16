import { useRouter } from 'expo-router';
import { useCallback, useEffect } from 'react';
import { StyleSheet, View } from 'react-native';
import { GalleryOverlay } from '../components/GalleryOverlay';
import { GALLERY_IMAGES } from '../galleryImages';
import { useSharedElementTransition } from '../SharedElementTransitionContext';

export default function ImageGalleryOverlayRoute() {
  const router = useRouter();
  const {
    activeIndex,
    closeOverlay,
    hiddenIndex,
    initialOriginRect,
    measureItem,
    originIndex,
    originRect,
    updateActiveIndex,
  } = useSharedElementTransition();

  useEffect(() => {
    return () => {
      hiddenIndex.set(-1);
      closeOverlay();
    };
  }, [closeOverlay, hiddenIndex]);

  const onClosed = useCallback(() => {
    closeOverlay();
    router.back();
  }, [closeOverlay, router]);

  const onIndexChange = useCallback(
    (index: number) => {
      const image = GALLERY_IMAGES[index];
      if (!image) return;
      updateActiveIndex(index);
      measureItem(image.id, index);
    },
    [measureItem, updateActiveIndex]
  );

  return (
    <View pointerEvents="box-none" style={styles.root}>
      <GalleryOverlay
        activeIndex={activeIndex}
        hiddenIndex={hiddenIndex}
        initialOriginRect={initialOriginRect}
        onClosed={onClosed}
        onIndexChange={onIndexChange}
        originIndex={originIndex}
        originRect={originRect}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  root: { backgroundColor: 'transparent', flex: 1 },
});
