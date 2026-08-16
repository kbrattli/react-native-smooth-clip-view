import { Image } from 'expo-image';
import { memo } from 'react';
import { StyleSheet, View } from 'react-native';
import { resolveAspectFitFrame } from '../galleryGeometry';
import type { GalleryImage } from '../galleryImages';
import { SCREEN_HEIGHT, SCREEN_WIDTH } from '../overlayConstants';

type GalleryImagePageProps = {
  image: GalleryImage;
  index: number;
  openingIndex: number;
  onOpeningImageDisplay: (imageId: string, index: number) => void;
  onOpeningImageLayout: (imageId: string, index: number) => void;
};

const GalleryImagePage = memo(function GalleryImagePageView({
  image,
  index,
  openingIndex,
  onOpeningImageDisplay,
  onOpeningImageLayout,
}: GalleryImagePageProps) {
  const destinationFrame = resolveAspectFitFrame(
    SCREEN_WIDTH,
    SCREEN_HEIGHT,
    image.width,
    image.height
  );
  const isOpeningPage = index === openingIndex;

  return (
    <View
      accessibilityLabel={image.accessibilityLabel}
      pointerEvents="none"
      style={styles.page}
      testID={`gallery-page-${image.id}`}
    >
      <View
        onLayout={
          isOpeningPage
            ? () => onOpeningImageLayout(image.id, index)
            : undefined
        }
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
        <Image
          cachePolicy="memory-disk"
          contentFit="cover"
          onDisplay={
            isOpeningPage
              ? () => onOpeningImageDisplay(image.id, index)
              : undefined
          }
          recyclingKey={image.id}
          source={image.source}
          style={styles.image}
          transition={0}
        />
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
  image: { height: '100%', width: '100%' },
});
