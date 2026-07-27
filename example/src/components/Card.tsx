import { Image, StyleSheet, Text, View } from 'react-native';
import { StressWorkload } from './StressWorkload';

const stressBackground = require('../../assets/stress-background.jpg');

type CardProps = {
  index: number;
  maximumHeight: number;
  maximumWidth: number;
};

/** Static content keeps clip-driver traces free of unrelated worklets. */
export function Card({ index, maximumHeight, maximumWidth }: CardProps) {
  return (
    <View style={styles.card}>
      <Image
        resizeMode="cover"
        source={stressBackground}
        style={StyleSheet.absoluteFill}
      />
      <View pointerEvents="none" style={StyleSheet.absoluteFill}>
        <StressWorkload
          height={maximumHeight}
          hostIndex={index}
          width={maximumWidth}
        />
        <View style={styles.scrim} />
        <View style={styles.glow} />
        <View style={styles.cardContent}>
          <Text style={styles.cardKicker}>STRESS HOST {index + 1}</Text>
          <Text numberOfLines={2} style={styles.cardTitle}>
            Atomic geometry under load.
          </Text>
          <View style={styles.metricBadge}>
            <Text style={styles.metricText}>IMAGE + CONTENT</Text>
          </View>
        </View>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    backgroundColor: '#112743',
    borderRadius: 18,
    flex: 1,
    overflow: 'hidden',
  },
  scrim: {
    backgroundColor: 'rgba(4, 15, 28, 0.48)',
    bottom: 0,
    left: 0,
    position: 'absolute',
    right: 0,
    top: 0,
  },
  glow: {
    backgroundColor: '#0CA7C7',
    borderRadius: 80,
    height: 150,
    opacity: 0.28,
    position: 'absolute',
    right: -65,
    top: -65,
    width: 150,
  },
  cardContent: { flex: 1, padding: 14 },
  cardKicker: {
    color: '#7DE9FF',
    fontSize: 9,
    fontWeight: '800',
    letterSpacing: 1.1,
  },
  cardTitle: {
    color: '#FFFFFF',
    fontSize: 17,
    fontWeight: '800',
    letterSpacing: -0.3,
    lineHeight: 20,
    marginTop: 8,
  },
  metricBadge: {
    alignSelf: 'flex-start',
    backgroundColor: 'rgba(7, 17, 31, 0.72)',
    borderColor: 'rgba(125, 233, 255, 0.45)',
    borderRadius: 8,
    borderWidth: StyleSheet.hairlineWidth,
    marginTop: 'auto',
    paddingHorizontal: 8,
    paddingVertical: 5,
  },
  metricText: {
    color: '#D6F8FF',
    fontSize: 8,
    fontWeight: '800',
    letterSpacing: 0.7,
  },
});
