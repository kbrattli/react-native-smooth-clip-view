import { useCallback, useEffect, useMemo, useState } from 'react';
import { StyleSheet, Text, useWindowDimensions, View } from 'react-native';
import {
  cancelAnimation,
  Easing,
  useDerivedValue,
  useSharedValue,
  withRepeat,
  withTiming,
} from 'react-native-reanimated';
import { Button } from './Button';
import {
  AnimatedLayoutStressItem,
  SmoothClipStressItem,
} from './StressTestItem';
import { getStressClipGeometry } from '../stressGeometry';
import { STRESS_HOST_COUNT } from '../stressWorkload';

export type StressImplementation = 'smooth-clip' | 'animated-layout';

type StressTestScreenProps = { implementation: StressImplementation };

const GRID_GAP = 12;
const GRID_HORIZONTAL_INSET = 18;
const GRID_MAX_WIDTH = 440;
const CARD_ASPECT_RATIO = 1.08;
const HALF_OSCILLATION_MS = 650;

export function StressTestScreen({ implementation }: StressTestScreenProps) {
  const { width: windowWidth } = useWindowDimensions();
  const [running, setRunning] = useState(false);
  const progress = useSharedValue(0);
  const gridWidth = Math.min(
    GRID_MAX_WIDTH,
    Math.max(0, windowWidth - GRID_HORIZONTAL_INSET * 2)
  );
  const cardWidth = (gridWidth - GRID_GAP) / 2;
  const cardHeight = cardWidth * CARD_ASPECT_RATIO;
  const initialClip = useMemo(
    () => getStressClipGeometry(0, cardWidth, cardHeight),
    [cardHeight, cardWidth]
  );
  const animatedClip = useDerivedValue(() =>
    getStressClipGeometry(progress.value, cardWidth, cardHeight)
  );
  const dimensionKey = `${Math.round(cardWidth)}x${Math.round(cardHeight)}`;

  const resetAnimation = useCallback(() => {
    cancelAnimation(progress);
    progress.value = 0;
  }, [progress]);

  useEffect(() => resetAnimation, [resetAnimation]);

  const toggleAnimation = useCallback(() => {
    if (running) {
      resetAnimation();
      setRunning(false);
      return;
    }
    progress.value = withRepeat(
      withTiming(1, {
        duration: HALF_OSCILLATION_MS,
        easing: Easing.inOut(Easing.cubic),
      }),
      -1,
      true
    );
    setRunning(true);
  }, [progress, resetAnimation, running]);

  const Item =
    implementation === 'smooth-clip'
      ? SmoothClipStressItem
      : AnimatedLayoutStressItem;

  return (
    <View style={styles.screen} testID={`stress-screen-${implementation}-root`}>
      <View style={styles.controls}>
        <Text style={styles.modeLabel}>
          {implementation === 'smooth-clip'
            ? 'SmoothClipView · fixed Yoga footprint, clip-only updates'
            : 'Width/height interpolation · per-frame layout + commit'}
        </Text>
        <Button onPress={toggleAnimation} running={running} />
      </View>

      <View
        key={`${implementation}-${dimensionKey}`}
        style={[styles.grid, { width: cardWidth * 2 + GRID_GAP }]}
        testID={`stress-grid-${implementation}`}
      >
        {Array.from({ length: STRESS_HOST_COUNT }, (_, index) => (
          <Item
            animatedClip={animatedClip}
            height={cardHeight}
            index={index}
            initialClip={initialClip}
            key={index}
            width={cardWidth}
          />
        ))}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { marginTop: 14 },
  controls: { alignItems: 'center', paddingHorizontal: GRID_HORIZONTAL_INSET },
  modeLabel: {
    color: '#8397AF',
    fontSize: 12,
    fontWeight: '700',
    letterSpacing: 0.2,
  },
  grid: {
    alignSelf: 'center',
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: GRID_GAP,
    marginTop: 18,
  },
});
