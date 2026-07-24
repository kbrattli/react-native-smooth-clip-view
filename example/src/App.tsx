import { StatusBar } from 'expo-status-bar';
import { useRef, useState } from 'react';
import { Pressable, SafeAreaView, StyleSheet, Text, View } from 'react-native';
import {
  type ClipGeometry,
  SmoothClipView,
} from 'react-native-smooth-clip-view';
import {
  default as Animated,
  Easing,
  interpolate,
  useAnimatedStyle,
  useDerivedValue,
  useSharedValue,
  withTiming,
} from 'react-native-reanimated';

const HOST_WIDTH = 320;
const HOST_HEIGHT = 360;

const COLLAPSED_CLIP: ClipGeometry = {
  x: 108,
  y: 105,
  width: 104,
  height: 104,
  radius: 52,
};

const COLLAPSED_CONTENT_SCALE = COLLAPSED_CLIP.width / HOST_WIDTH;

export default function App() {
  const [expanded, setExpanded] = useState(false);
  const expandedTarget = useRef(false);
  const progress = useSharedValue(0);
  const animatedClip = useDerivedValue<ClipGeometry>(() => ({
    x: interpolate(progress.value, [0, 1], [COLLAPSED_CLIP.x, 0]),
    y: interpolate(progress.value, [0, 1], [COLLAPSED_CLIP.y, 0]),
    width: interpolate(
      progress.value,
      [0, 1],
      [COLLAPSED_CLIP.width, HOST_WIDTH]
    ),
    height: interpolate(
      progress.value,
      [0, 1],
      [COLLAPSED_CLIP.height, HOST_HEIGHT]
    ),
    radius: interpolate(progress.value, [0, 1], [COLLAPSED_CLIP.radius, 32]),
  }));
  const animatedContentStyle = useAnimatedStyle(() => ({
    opacity: interpolate(progress.value, [0, 0.35, 1], [0, 0, 1]),
    transform: [
      {
        scale: interpolate(
          progress.value,
          [0, 1],
          [COLLAPSED_CONTENT_SCALE, 1]
        ),
      },
    ],
  }));

  const toggleClip = () => {
    const nextExpanded = !expandedTarget.current;
    expandedTarget.current = nextExpanded;
    setExpanded(nextExpanded);
    progress.value = withTiming(nextExpanded ? 1 : 0, {
      duration: 650,
      easing: Easing.inOut(Easing.cubic),
    });
  };

  return (
    <SafeAreaView style={styles.safeArea}>
      <StatusBar style="light" />
      <View style={styles.container}>
        <Text style={styles.eyebrow}>FABRIC + REANIMATED</Text>
        <Text style={styles.title}>Smooth clip, fixed layout.</Text>
        <Text style={styles.description}>
          Animate width and height without expensive layout calculations while
          preserving a smooth border radius.
        </Text>

        <View style={styles.stage}>
          <SmoothClipView
            initialClip={COLLAPSED_CLIP}
            animatedClip={animatedClip}
            style={styles.clipHost}
          >
            <View style={styles.card}>
              <View style={styles.glowLarge} />
              <View style={styles.glowSmall} />
              <Animated.View style={[styles.cardContent, animatedContentStyle]}>
                <Text style={styles.cardKicker}>REVEAL WINDOW</Text>
                <Text style={styles.cardTitle}>
                  One atomic geometry update.
                </Text>
                <Text style={styles.cardCopy}>
                  Position, size, and corner radius travel together on the UI
                  runtime.
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
          </SmoothClipView>
        </View>

        <Pressable
          accessibilityRole="button"
          onPress={toggleClip}
          style={({ pressed }) => [
            styles.button,
            pressed ? styles.buttonPressed : null,
          ]}
        >
          <Text style={styles.buttonText}>
            {expanded ? 'Collapse clip' : 'Expand clip'}
          </Text>
        </Pressable>
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safeArea: {
    flex: 1,
    backgroundColor: '#07111F',
  },
  container: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 24,
    paddingVertical: 28,
  },
  eyebrow: {
    color: '#66E3FF',
    fontSize: 12,
    fontWeight: '800',
    letterSpacing: 1.8,
  },
  title: {
    color: '#F7FAFF',
    fontSize: 30,
    fontWeight: '800',
    letterSpacing: -0.8,
    marginTop: 10,
    textAlign: 'center',
  },
  description: {
    color: '#9FB0C7',
    fontSize: 15,
    lineHeight: 22,
    marginTop: 10,
    maxWidth: 360,
    textAlign: 'center',
  },
  stage: {
    height: HOST_HEIGHT,
    marginTop: 26,
    width: HOST_WIDTH,
  },
  clipHost: {
    height: HOST_HEIGHT,
    width: HOST_WIDTH,
  },
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
  button: {
    alignItems: 'center',
    backgroundColor: '#66E3FF',
    borderRadius: 16,
    marginTop: 24,
    minWidth: 180,
    paddingHorizontal: 24,
    paddingVertical: 15,
  },
  buttonPressed: {
    opacity: 0.72,
    transform: [{ scale: 0.98 }],
  },
  buttonText: {
    color: '#06121F',
    fontSize: 15,
    fontWeight: '800',
  },
});
