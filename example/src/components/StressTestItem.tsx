import { useEffect, useRef } from 'react';
import { StyleSheet, View } from 'react-native';
import Animated, {
  type SharedValue,
  useAnimatedReaction,
  useAnimatedStyle,
} from 'react-native-reanimated';
import {
  type ClipGeometry,
  type SmoothClipDriver,
  SmoothClipView,
  createClipPresentation,
  useSmoothClipDriver,
} from 'react-native-smooth-clip-view';
import { Card } from './Card';
import { LegacySmoothClipView } from './LegacySmoothClipView';

type StressTestItemProps = {
  animatedClip: SharedValue<ClipGeometry>;
  expandedClip: ClipGeometry;
  height: number;
  handoffRun: number;
  index: number;
  initialClip: ClipGeometry;
  running: boolean;
  width: number;
};

type DriverStressItemProps = StressTestItemProps & {
  driver: SmoothClipDriver;
};

const TIMING = {
  type: 'timing',
  duration: 650,
  controlPoints: [0.645, 0.045, 0.355, 1] as const,
} as const;

function ignoreRequest(request: Promise<unknown>): void {
  request.catch(() => undefined);
}

function ClipHost({
  driver,
  height,
  index,
  width,
}: Pick<DriverStressItemProps, 'driver' | 'height' | 'index' | 'width'>) {
  const maximumSize = { height, width };
  return (
    <View style={[styles.stage, maximumSize]}>
      <SmoothClipView
        driver={driver}
        style={[styles.maximumHost, maximumSize]}
        testID={`stress-smooth-host-${index}`}
      >
        <Card index={index} maximumHeight={height} maximumWidth={width} />
      </SmoothClipView>
    </View>
  );
}

export function SharedDriverStressItem(props: DriverStressItemProps) {
  return <ClipHost {...props} />;
}

export function DirectStressItem(props: StressTestItemProps) {
  const driver = useBoundDriver(props.initialClip, props.animatedClip);
  return <ClipHost {...props} driver={driver} />;
}

export function ScalarStressItem(props: StressTestItemProps) {
  const driver = useBoundScalarsDriver(props.initialClip, props.animatedClip);
  return <ClipHost {...props} driver={driver} />;
}

export function NativeStressItem(props: StressTestItemProps) {
  const driver = useLoopingDriver(
    props.initialClip,
    props.expandedClip,
    props.running,
    props.handoffRun
  );
  return <ClipHost {...props} driver={driver} />;
}

export function useBoundDriver(
  initialClip: ClipGeometry,
  animatedClip: SharedValue<ClipGeometry>
) {
  const driver = useSmoothClipDriver(initialClip);
  useAnimatedReaction(
    () => animatedClip.value,
    (nextClip) => {
      driver.presentation.value = createClipPresentation(nextClip);
    },
    [animatedClip, driver.presentation]
  );
  return driver;
}

/**
 * Scalar hot-path binding: per-frame geometry goes straight to native without
 * a SharedValue write, for A/B measurement against useBoundDriver.
 */
export function useBoundScalarsDriver(
  initialClip: ClipGeometry,
  animatedClip: SharedValue<ClipGeometry>
) {
  const driver = useSmoothClipDriver(initialClip);
  useAnimatedReaction(
    () => animatedClip.value,
    (nextClip) => {
      driver.ui.setScalars(
        nextClip.x,
        nextClip.y,
        nextClip.width,
        nextClip.height,
        nextClip.radius,
        0,
        0
      );
    },
    [animatedClip, driver]
  );
  return driver;
}

export function useLoopingDriver(
  collapsed: ClipGeometry,
  expanded: ClipGeometry,
  running: boolean,
  handoffRun = 0
) {
  const activeRef = useRef(false);
  const nextTargetRef = useRef(expanded);
  const reverseTargetRef = useRef(collapsed);
  const driverRef = useRef<SmoothClipDriver | null>(null);
  const driver = useSmoothClipDriver(collapsed, {
    onAnimationComplete: ({ finished }) => {
      const currentDriver = driverRef.current;
      if (!activeRef.current || !finished || !currentDriver) return;
      const target = nextTargetRef.current;
      nextTargetRef.current = reverseTargetRef.current;
      reverseTargetRef.current = target;
      ignoreRequest(
        currentDriver.react.animateTo(createClipPresentation(target), TIMING)
      );
    },
  });
  driverRef.current = driver;

  useEffect(() => {
    activeRef.current = true;
    nextTargetRef.current = collapsed;
    reverseTargetRef.current = expanded;
    ignoreRequest(driver.react.set(createClipPresentation(collapsed)));
    if (!running) return () => undefined;
    nextTargetRef.current = collapsed;
    reverseTargetRef.current = expanded;
    ignoreRequest(
      driver.react.animateTo(createClipPresentation(expanded), TIMING)
    );
    return () => {
      activeRef.current = false;
      ignoreRequest(driver.react.cancel(undefined, 'current'));
    };
  }, [collapsed, driver, expanded, running]);

  useEffect(() => {
    if (handoffRun === 0) return undefined;
    activeRef.current = false;
    let cancelled = false;
    let frame = 0;
    ignoreRequest(
      driver.react.beginInteraction().then(async (visible) => {
        if (cancelled) return;
        await driver.react.set({
          ...visible,
          clip: {
            ...visible.clip,
            height: Math.max(0, visible.clip.height - 8),
          },
        });
        if (cancelled) return;
        frame = requestAnimationFrame(() => {
          ignoreRequest(
            driver.react.animateTo(createClipPresentation(expanded), {
              type: 'spring',
              initialVelocity: 'inherit',
            })
          );
        });
      })
    );
    return () => {
      cancelled = true;
      if (frame !== 0) cancelAnimationFrame(frame);
    };
  }, [driver, expanded, handoffRun]);
  return driver;
}

export function LegacySmoothClipStressItem({
  animatedClip,
  height,
  index,
  initialClip,
  width,
}: StressTestItemProps) {
  const maximumSize = { height, width };
  return (
    <View style={[styles.stage, maximumSize]}>
      <LegacySmoothClipView
        animatedClip={animatedClip}
        initialClip={initialClip}
        style={[styles.maximumHost, maximumSize]}
        testID={`stress-legacy-host-${index}`}
      >
        <Card index={index} maximumHeight={height} maximumWidth={width} />
      </LegacySmoothClipView>
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
