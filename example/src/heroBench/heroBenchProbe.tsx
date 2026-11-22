import { useCallback, useEffect, useRef } from 'react';
import { StyleSheet, type HostInstance } from 'react-native';
import Animated, {
  makeMutable,
  useAnimatedStyle,
  useFrameCallback,
} from 'react-native-reanimated';
import { useHeroBenchSettings } from './heroBenchSettings';

// UI-runtime state, written by the card's tap worklet.
const markerLit = makeMutable(false);
const busyLoadMs = makeMutable(0);

/** Lights the tap marker; call it in the UI-thread turn of the touch-up. */
export function lightHeroBenchMarker() {
  'worklet';
  markerLit.set(true);
}

export function clearHeroBenchMarker() {
  markerLit.set(false);
}

/** Holds the calling (JS) thread: the bench's `JS block`. */
export function blockJsThread(ms: number) {
  const end = performance.now() + ms;
  while (performance.now() < end) {
    // Busy-wait.
  }
}

/**
 * `Busy 14`: burns main-thread time in every UI frame while it is selected,
 * standing in for app work that competes with a transition. The frame that
 * delivers the tap is already busy. Mounted once at the root so it survives
 * navigation.
 */
export function HeroBenchProbe() {
  const { busyMs } = useHeroBenchSettings();
  const busy = useFrameCallback(() => {
    'worklet';
    const load = busyLoadMs.get();
    if (load <= 0) return;
    const clock = globalThis as unknown as {
      _getAnimationTimestamp: () => number;
    };
    const begin = clock._getAnimationTimestamp();
    while (clock._getAnimationTimestamp() - begin < load) {
      // Busy-wait: hold the main thread for the configured load.
    }
  }, false);
  useEffect(() => {
    busyLoadMs.set(busyMs);
    busy.setActive(busyMs > 0);
  }, [busy, busyMs]);
  return null;
}

declare global {
  // Window rect of HeroBenchTapMarker, read by scripts/hero-bench/record.sh.
  var __heroBenchMarker:
    { x: number; y: number; width: number; height: number } | undefined;
}

/**
 * A square in the bottom-right corner, above every screen, lit white by the
 * card's tap worklet in the main-thread turn that delivers the touch-up. Both
 * implementations light it the same way, so in a recording it marks the tap
 * for SET and for a flight alike, whatever the JS thread is doing.
 */
export function HeroBenchTapMarker() {
  const ref = useRef<HostInstance>(null);
  const publishRect = useCallback(() => {
    ref.current?.measureInWindow((x, y, width, height) => {
      globalThis.__heroBenchMarker = { x, y, width, height };
    });
  }, []);
  const style = useAnimatedStyle(() => ({
    backgroundColor: markerLit.get() ? '#FFFFFF' : 'transparent',
  }));
  return (
    <Animated.View
      onLayout={publishRect}
      pointerEvents="none"
      ref={ref}
      style={[styles.marker, style]}
      testID="hero-bench-marker"
    />
  );
}

const styles = StyleSheet.create({
  marker: {
    bottom: 44,
    height: 16,
    position: 'absolute',
    right: 12,
    width: 16,
  },
});
