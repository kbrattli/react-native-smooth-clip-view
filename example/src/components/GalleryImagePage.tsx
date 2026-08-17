import { Image, useImage, type ImageRef } from 'expo-image';
import { memo } from 'react';
import { StyleSheet, useWindowDimensions, View } from 'react-native';
import Animated, {
  useAnimatedStyle,
  type SharedValue,
} from 'react-native-reanimated';
import { resolveAspectFitFrame } from '../galleryGeometry';
import type { GalleryImage } from '../galleryImages';
import { galleryCellSize, galleryThumbOptions } from '../galleryThumb';
import { SCREEN_HEIGHT, SCREEN_WIDTH } from '../overlayConstants';

type GalleryImagePageProps = {
  closingIndex: SharedValue<number>;
  contentScale: SharedValue<number>;
  currentIndex: SharedValue<number>;
  image: GalleryImage;
  index: number;
  onThumbDisplay?: () => void;
  openingThumbRef?: ImageRef | null;
};

const GalleryImagePage = memo(function GalleryImagePageView({
  closingIndex,
  contentScale,
  currentIndex,
  image,
  index,
  onThumbDisplay,
  openingThumbRef,
}: GalleryImagePageProps) {
  const destinationFrame = resolveAspectFitFrame(
    SCREEN_WIDTH,
    SCREEN_HEIGHT,
    image.width,
    image.height
  );

  // Bottom-layer source: the same grid-cell decode the tile already made
  // (identical options -> cache hit, not a second decode). The opening page
  // borrows the tapped tile's live ref so pixels exist in the overlay's very
  // first frame — useImage always resolves async — then hands off to the
  // hook-owned ref for the same bitmap the moment it lands.
  const { width: windowWidth } = useWindowDimensions();
  const thumbOptions = galleryThumbOptions(image, galleryCellSize(windowWidth));
  const ownThumb = useImage(
    image.source,
    { maxWidth: thumbOptions.maxWidth, maxHeight: thumbOptions.maxHeight },
    [image.id, thumbOptions.cellPixelSize]
  );
  const thumbSource = ownThumb ?? openingThumbRef ?? null;

  // The aspect-fit frame is centered on screen, so scaling this page about its
  // own center is equivalent to scaling the whole clip content about the
  // screen center — scoping the transform here keeps sibling pages out of the
  // re-composited subtree while the clip animates.
  const scaleStyle = useAnimatedStyle(() => {
    const isActive =
      currentIndex.get() === index || closingIndex.get() === index;
    return { transform: [{ scale: isActive ? contentScale.get() : 1 }] };
  });

  return (
    <View
      accessibilityLabel={image.accessibilityLabel}
      pointerEvents="none"
      style={styles.page}
      testID={`gallery-page-${image.id}`}
    >
      <View
        style={[
          styles.imageFrame,
          {
            height: destinationFrame.height,
            left: destinationFrame.x,
            top: destinationFrame.y,
            width: destinationFrame.width,
          },
        ]}
      >
        <Animated.View style={[styles.imageFill, scaleStyle]}>
          {/*
            Two stacked copies of the same picture guarantee the frame is never
            empty: the thumb (aspect-preserved downsample, so it aligns with
            the full-res layer to the pixel) is on screen from the first frame,
            and the fullscreen decode simply paints over it whenever it lands —
            the swap is sharpness only, with zero geometry change.
          */}
          <Image
            contentFit="cover"
            onDisplay={onThumbDisplay}
            recyclingKey={image.id}
            source={thumbSource}
            style={styles.layer}
            transition={0}
          />
          <Image
            cachePolicy="memory-disk"
            contentFit="cover"
            recyclingKey={image.id}
            source={image.source}
            style={styles.layer}
            transition={0}
          />
        </Animated.View>
      </View>
    </View>
  );
});
GalleryImagePage.displayName = 'GalleryImagePage';

export default GalleryImagePage;

const styles = StyleSheet.create({
  page: {
    height: SCREEN_HEIGHT,
    width: SCREEN_WIDTH,
  },
  imageFrame: { position: 'absolute' },
  imageFill: { height: '100%', width: '100%' },
  layer: { ...StyleSheet.absoluteFill },
});
