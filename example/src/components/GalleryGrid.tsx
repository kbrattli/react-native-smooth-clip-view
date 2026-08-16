import { LegendList, type LegendListRef } from '@legendapp/list/react-native';
import { Image } from 'expo-image';
import { memo, useCallback, useEffect, useRef } from 'react';
import {
  StyleSheet,
  useWindowDimensions,
  type HostInstance,
} from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import Animated, {
  measure,
  type AnimatedRef,
  type SharedValue,
  useAnimatedRef,
  useAnimatedStyle,
} from 'react-native-reanimated';
import { scheduleOnRN, scheduleOnUI } from 'react-native-worklets';
import { galleryImageKeyExtractor, type GalleryImage } from '../galleryImages';
import type { Rect } from '../zoomCities';

const COLUMN_COUNT = 3;

type ItemRef = AnimatedRef<HostInstance>;

type GalleryTileProps = {
  cellSize: number;
  hiddenIndex: SharedValue<number>;
  image: GalleryImage;
  index: number;
  onItemMeasured: (payload: { index: number; rect: Rect }) => void;
  onRegisterRef: (itemId: string, ref: ItemRef | null) => void;
  originRect: SharedValue<Rect>;
};

const GalleryTile = memo(function GalleryTileView({
  cellSize,
  hiddenIndex,
  image,
  index,
  onItemMeasured,
  onRegisterRef,
  originRect,
}: GalleryTileProps) {
  const measureRef = useAnimatedRef();

  useEffect(() => {
    onRegisterRef(image.id, measureRef);
    return () => onRegisterRef(image.id, null);
  }, [image.id, measureRef, onRegisterRef]);

  const openMeasuredItem = useCallback(() => {
    scheduleOnUI(
      (
        targetRef: ItemRef,
        targetOriginRect: SharedValue<Rect>,
        targetIndex: number,
        onMeasured: (payload: { index: number; rect: Rect }) => void
      ) => {
        'worklet';
        const measured = measure(targetRef);
        if (!measured) return;
        const rect: Rect = {
          x: measured.pageX,
          y: measured.pageY,
          w: measured.width,
          h: measured.height,
        };
        targetOriginRect.set(rect);
        scheduleOnRN(onMeasured, { index: targetIndex, rect });
      },
      measureRef,
      originRect,
      index,
      onItemMeasured
    );
  }, [index, measureRef, onItemMeasured, originRect]);

  const tapGesture = Gesture.Tap().onEnd(() => {
    'worklet';
    const measured = measure(measureRef);
    if (!measured) return;
    const rect: Rect = {
      x: measured.pageX,
      y: measured.pageY,
      w: measured.width,
      h: measured.height,
    };
    originRect.set(rect);
    scheduleOnRN(onItemMeasured, { index, rect });
  });

  const containerStyle = useAnimatedStyle(() => ({
    opacity: hiddenIndex.get() === index ? 0 : 1,
  }));

  return (
    <Animated.View
      style={[
        styles.tileContainer,
        { height: cellSize, width: cellSize },
        containerStyle,
      ]}
    >
      <Animated.View
        pointerEvents="none"
        ref={measureRef}
        style={styles.measureFill}
      />
      <GestureDetector gesture={tapGesture}>
        <Animated.View
          accessibilityLabel={image.accessibilityLabel}
          accessibilityRole="button"
          accessible
          onAccessibilityTap={openMeasuredItem}
          style={styles.tile}
          testID={`gallery-tile-${image.id}`}
        >
          <Image
            cachePolicy="memory-disk"
            contentFit="cover"
            recyclingKey={image.id}
            source={image.source}
            style={styles.image}
            transition={0}
          />
        </Animated.View>
      </GestureDetector>
    </Animated.View>
  );
});
GalleryTile.displayName = 'GalleryTile';

type GalleryGridProps = {
  activeIndex: number | null;
  hiddenIndex: SharedValue<number>;
  images: readonly GalleryImage[];
  onActiveItemReady: (itemId: string, index: number) => void;
  onItemMeasured: (payload: { index: number; rect: Rect }) => void;
  onRegisterRef: (itemId: string, ref: ItemRef | null) => void;
  originRect: SharedValue<Rect>;
};

export function GalleryGrid({
  activeIndex,
  hiddenIndex,
  images,
  onActiveItemReady,
  onItemMeasured,
  onRegisterRef,
  originRect,
}: GalleryGridProps) {
  const { height, width } = useWindowDimensions();
  const cellSize = width / COLUMN_COUNT;
  const listRef = useRef<LegendListRef>(null);
  const previousActiveIndexRef = useRef<number | null>(null);

  useEffect(() => {
    if (activeIndex === null) {
      previousActiveIndexRef.current = null;
      return;
    }

    const previousIndex = previousActiveIndexRef.current;
    previousActiveIndexRef.current = activeIndex;
    if (previousIndex === null || previousIndex === activeIndex) return;

    const list = listRef.current;
    const image = images[activeIndex];
    if (!list || !image) return;

    let cancelled = false;
    list
      .scrollToIndex({ animated: false, index: activeIndex, viewPosition: 0.5 })
      .then(() => {
        requestAnimationFrame(() => {
          requestAnimationFrame(() => {
            if (!cancelled) onActiveItemReady(image.id, activeIndex);
          });
        });
      });

    return () => {
      cancelled = true;
    };
  }, [activeIndex, images, onActiveItemReady]);

  const renderItem = useCallback(
    ({ item, index }: { item: GalleryImage; index: number }) => (
      <GalleryTile
        cellSize={cellSize}
        hiddenIndex={hiddenIndex}
        image={item}
        index={index}
        onItemMeasured={onItemMeasured}
        onRegisterRef={onRegisterRef}
        originRect={originRect}
      />
    ),
    [cellSize, hiddenIndex, onItemMeasured, onRegisterRef, originRect]
  );
  const getFixedItemSize = useCallback(() => cellSize, [cellSize]);

  return (
    <LegendList
      data={images as GalleryImage[]}
      drawDistance={cellSize * 2}
      estimatedItemSize={cellSize}
      estimatedListSize={{ width, height }}
      getFixedItemSize={getFixedItemSize}
      keyExtractor={galleryImageKeyExtractor}
      numColumns={COLUMN_COUNT}
      recycleItems
      ref={listRef}
      renderItem={renderItem}
      showsVerticalScrollIndicator={false}
      style={styles.list}
      testID="gallery-grid"
    />
  );
}

const styles = StyleSheet.create({
  list: { backgroundColor: '#000000', flex: 1 },
  tileContainer: { backgroundColor: '#000000' },
  measureFill: {
    bottom: 0,
    left: 0,
    opacity: 0,
    position: 'absolute',
    right: 0,
    top: 0,
  },
  tile: { flex: 1, overflow: 'hidden' },
  image: { height: '100%', width: '100%' },
});
