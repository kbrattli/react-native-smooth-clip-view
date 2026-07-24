import { StatusBar } from 'expo-status-bar';
import { useState } from 'react';
import { SafeAreaView, StyleSheet, View } from 'react-native';
import {
  type ClipGeometry,
  SmoothClipView,
} from 'react-native-smooth-clip-view';
import {
  Easing,
  interpolate,
  useDerivedValue,
  useSharedValue,
  withTiming,
} from 'react-native-reanimated';
import { Button } from './components/Button';
import { Card } from './components/Card';
import { Header } from './components/Header';

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
  const toggleClip = () => {
    setExpanded((currentExpanded) => {
      const nextExpanded = !currentExpanded;
      progress.value = withTiming(nextExpanded ? 1 : 0, {
        duration: 650,
        easing: Easing.inOut(Easing.cubic),
      });
      return nextExpanded;
    });
  };

  return (
    <SafeAreaView style={styles.safeArea}>
      <StatusBar style="light" />
      <View style={styles.container}>
        <Header />

        <View style={styles.stage}>
          <SmoothClipView
            initialClip={COLLAPSED_CLIP}
            animatedClip={animatedClip}
            style={styles.clipHost}
          >
            <Card
              collapsedScale={COLLAPSED_CONTENT_SCALE}
              progress={progress}
            />
          </SmoothClipView>
        </View>

        <Button expanded={expanded} onPress={toggleClip} />
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
  stage: {
    height: HOST_HEIGHT,
    marginTop: 26,
    width: HOST_WIDTH,
  },
  clipHost: {
    height: HOST_HEIGHT,
    width: HOST_WIDTH,
  },
});
