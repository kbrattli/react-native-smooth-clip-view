import { StyleSheet, Text, View } from 'react-native';
import Animated, {
  interpolate,
  type SharedValue,
  useAnimatedStyle,
} from 'react-native-reanimated';

type CardProps = {
  collapsedScale: number;
  progress: SharedValue<number>;
};

export function Card({ collapsedScale, progress }: CardProps) {
  const animatedContentStyle = useAnimatedStyle(() => ({
    opacity: interpolate(progress.value, [0, 0.35, 1], [0, 0, 1]),
    transform: [
      {
        scale: interpolate(progress.value, [0, 1], [collapsedScale, 1]),
      },
    ],
  }));

  return (
    <View style={styles.card}>
      <View style={styles.glowLarge} />
      <View style={styles.glowSmall} />
      <Animated.View style={[styles.cardContent, animatedContentStyle]}>
        <Text style={styles.cardKicker}>REVEAL WINDOW</Text>
        <Text style={styles.cardTitle}>One atomic geometry update.</Text>
        <Text style={styles.cardCopy}>
          Position, size, and corner radius travel together on the UI runtime.
        </Text>
        <View style={styles.metricRow}>
          <View style={styles.metricItem}>
            <Text style={styles.metricValue}>60 fps</Text>
            <Text style={styles.metricLabel}>layout-free target</Text>
          </View>
          <View style={styles.metricDivider} />
          <View style={styles.metricItem}>
            <Text style={styles.metricValue}>5 values</Text>
            <Text style={styles.metricLabel}>one native command</Text>
          </View>
        </View>
      </Animated.View>
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    backgroundColor: '#112743',
    borderRadius: 32,
    flex: 1,
    overflow: 'hidden',
  },
  cardContent: {
    flex: 1,
    padding: 30,
    paddingTop: 38,
  },
  glowLarge: {
    backgroundColor: '#0CA7C7',
    borderRadius: 120,
    height: 240,
    opacity: 0.38,
    position: 'absolute',
    right: -95,
    top: -90,
    width: 240,
  },
  glowSmall: {
    backgroundColor: '#7357FF',
    borderRadius: 75,
    bottom: -35,
    height: 150,
    left: -45,
    opacity: 0.34,
    position: 'absolute',
    width: 150,
  },
  cardKicker: {
    color: '#7DE9FF',
    fontSize: 11,
    fontWeight: '800',
    letterSpacing: 1.5,
  },
  cardTitle: {
    color: '#FFFFFF',
    flexShrink: 1,
    fontSize: 28,
    fontWeight: '800',
    letterSpacing: -0.6,
    lineHeight: 33,
    marginTop: 16,
    maxWidth: 250,
  },
  cardCopy: {
    color: '#B9C9DC',
    flexShrink: 1,
    fontSize: 15,
    lineHeight: 22,
    marginTop: 16,
    maxWidth: 255,
  },
  metricRow: {
    alignItems: 'center',
    flexDirection: 'row',
    marginTop: 'auto',
  },
  metricItem: {
    flex: 1,
    minWidth: 0,
  },
  metricValue: {
    color: '#FFFFFF',
    flexShrink: 1,
    fontSize: 17,
    fontWeight: '800',
  },
  metricLabel: {
    color: '#8397AF',
    flexShrink: 1,
    fontSize: 11,
    marginTop: 3,
  },
  metricDivider: {
    backgroundColor: '#496078',
    height: 34,
    marginHorizontal: 18,
    width: StyleSheet.hairlineWidth,
  },
});
