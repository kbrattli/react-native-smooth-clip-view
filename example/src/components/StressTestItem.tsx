import { StyleSheet, View } from 'react-native';
import Animated, {
  type SharedValue,
  useAnimatedReaction,
  useAnimatedStyle,
} from 'react-native-reanimated';
import {
  type ClipGeometry,
  SmoothClipView,
  createClipPresentation,
  useSmoothClipController,
} from 'react-native-smooth-clip-view';
import { Card } from './Card';

type StressTestItemProps = {
  animatedClip: SharedValue<ClipGeometry>;
  height: number;
  index: number;
  initialClip: ClipGeometry;
  width: number;
};

export function SmoothClipStressItem({
  animatedClip,
  height,
  index,
  initialClip,
  width,
}: StressTestItemProps) {
  const clip = useSmoothClipController(initialClip);
  useAnimatedReaction(
    () => animatedClip.value,
    (nextClip) => {
      clip.ui.setFrame(createClipPresentation(nextClip));
    },
    [animatedClip, clip]
  );
  const maximumSize = { height, width };
  return (
    <View style={[styles.stage, maximumSize]}>
      <SmoothClipView
        controller={clip}
        style={[styles.maximumHost, maximumSize]}
        testID={`stress-smooth-host-${index}`}
      >
        <Card index={index} maximumHeight={height} maximumWidth={width} />
      </SmoothClipView>
    </View>
  );
}

export function AnimatedLayoutStressItem({
  animatedClip,
  height,
  index,
  width,
}: StressTestItemProps) {
  const clipStyle = useAnimatedStyle(() => {
    const clip = animatedClip.value;
    return {
      borderRadius: clip.radius,
      height: clip.height,
      left: clip.x,
      top: clip.y,
      width: clip.width,
    };
  });
  const contentStyle = useAnimatedStyle(() => {
    const clip = animatedClip.value;
    return {
      transform: [{ translateX: -clip.x }, { translateY: -clip.y }],
    };
  });
  const maximumSize = { height, width };
  return (
    <View style={[styles.stage, maximumSize]}>
      <Animated.View style={[styles.layoutClipHost, clipStyle]}>
        <Animated.View style={[styles.maximumHost, maximumSize, contentStyle]}>
          <Card index={index} maximumHeight={height} maximumWidth={width} />
        </Animated.View>
      </Animated.View>
    </View>
  );
}

const styles = StyleSheet.create({
  stage: {
    backgroundColor: '#0B1828',
    borderColor: '#263E59',
    borderRadius: 18,
    borderWidth: StyleSheet.hairlineWidth,
    overflow: 'hidden',
    position: 'relative',
  },
  maximumHost: { left: 0, position: 'absolute', top: 0 },
  layoutClipHost: { overflow: 'hidden', position: 'absolute' },
});
