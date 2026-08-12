import { memo, useEffect } from 'react';
import { StyleSheet, Text, View, type HostInstance } from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import Animated, {
  measure,
  type AnimatedRef,
  type SharedValue,
  useAnimatedRef,
  useAnimatedStyle,
  useSharedValue,
  withTiming,
} from 'react-native-reanimated';
import { scheduleOnRN } from 'react-native-worklets';
import {
  CARD_GAP,
  CARD_HEIGHT,
  CARD_INSET,
  CARD_PADDING,
  OVERLAY_SOURCE_RADIUS,
} from '../overlayConstants';
import type { Rect, ZoomCity } from '../zoomCities';
import { CompactScoreDisplay } from './CompactScoreDisplay';

const PRESS_IN_SCALE = 0.97;
const PRESS_IN_CONFIG = { duration: 140 } as const;
const PRESS_RELEASE_CONFIG = { duration: 180 } as const;

type CardRef = AnimatedRef<HostInstance>;

type ZoomCardProps = {
  city: ZoomCity;
  hiddenIndex: SharedValue<number>;
  index: number;
  onCardMeasured: (payload: { index: number; rect: Rect }) => void;
  onRegisterRef: (cityId: string, ref: CardRef | null) => void;
  originRect: SharedValue<Rect>;
};

const ZoomCard = memo(
  ({
    city,
    hiddenIndex,
    index,
    onCardMeasured,
    onRegisterRef,
    originRect,
  }: ZoomCardProps) => {
    // A separate invisible fill sibling is what gets measured, so the card's own
    // press-scale transform can never pollute the rect the overlay opens from.
    const measureRef = useAnimatedRef();
    const pressScale = useSharedValue(1);

    // Registered for the whole mounted life of the card, so the overlay can
    // re-measure it after paging even while the modal covers this screen.
    useEffect(() => {
      onRegisterRef(city.id, measureRef);
      return () => onRegisterRef(city.id, null);
    }, [city.id, measureRef, onRegisterRef]);

    const tapGesture = Gesture.Tap()
      .onBegin(() => {
        'worklet';
        pressScale.set(withTiming(PRESS_IN_SCALE, PRESS_IN_CONFIG));
      })
      .onEnd(() => {
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
        scheduleOnRN(onCardMeasured, { index, rect });
      })
      .onFinalize(() => {
        'worklet';
        pressScale.set(withTiming(1, PRESS_RELEASE_CONFIG));
      });

    const containerStyle = useAnimatedStyle(() => ({
      opacity: hiddenIndex.get() === index ? 0 : 1,
    }));

    const cardStyle = useAnimatedStyle(() => ({
      transform: [{ scale: pressScale.get() }],
    }));

    return (
      <Animated.View style={[styles.cardContainer, containerStyle]}>
        <Animated.View
          pointerEvents="none"
          ref={measureRef}
          style={styles.measureFill}
        />
        <GestureDetector gesture={tapGesture}>
          <Animated.View
            style={[styles.card, { backgroundColor: city.color }, cardStyle]}
            testID={`zoom-card-${city.id}`}
          >
            <View style={styles.cardContent}>
              <Text allowFontScaling={false} style={styles.cardTitle}>
                {city.title}
              </Text>
              <CompactScoreDisplay score={city.score} />
            </View>
          </Animated.View>
        </GestureDetector>
      </Animated.View>
    );
  }
);
ZoomCard.displayName = 'ZoomCard';

type ZoomCardListProps = {
  cities: readonly ZoomCity[];
  hiddenIndex: SharedValue<number>;
  onCardMeasured: (payload: { index: number; rect: Rect }) => void;
  onRegisterRef: (cityId: string, ref: CardRef | null) => void;
  originRect: SharedValue<Rect>;
};

export function ZoomCardList({
  cities,
  hiddenIndex,
  onCardMeasured,
  onRegisterRef,
  originRect,
}: ZoomCardListProps) {
  return (
    <View style={styles.list} testID="zoom-card-list">
      {cities.map((city, index) => (
        <ZoomCard
          city={city}
          hiddenIndex={hiddenIndex}
          index={index}
          key={city.id}
          onCardMeasured={onCardMeasured}
          onRegisterRef={onRegisterRef}
          originRect={originRect}
        />
      ))}
    </View>
  );
}

const styles = StyleSheet.create({
  list: { paddingHorizontal: CARD_INSET, paddingTop: CARD_GAP },
  cardContainer: { height: CARD_HEIGHT, marginBottom: CARD_GAP },
  measureFill: {
    bottom: 0,
    left: 0,
    opacity: 0,
    position: 'absolute',
    right: 0,
    top: 0,
  },
  card: {
    borderRadius: OVERLAY_SOURCE_RADIUS,
    flex: 1,
    overflow: 'hidden',
  },
  cardContent: {
    alignItems: 'center',
    flex: 1,
    flexDirection: 'row',
    justifyContent: 'space-between',
    padding: CARD_PADDING,
  },
  cardTitle: {
    color: '#FFFFFF',
    fontSize: 24,
    fontWeight: '700',
    lineHeight: 32,
  },
});
