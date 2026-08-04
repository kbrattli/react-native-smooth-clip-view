import { useCallback, useEffect, useRef, useState } from 'react';
import { Dimensions, Pressable, StyleSheet, Text, View } from 'react-native';
import {
  useAnimatedReaction,
  useSharedValue,
  withTiming,
  Easing,
} from 'react-native-reanimated';
import {
  ClipEasings,
  type SmoothClipPresentation,
  SmoothClipView,
  useSmoothClipDriver,
} from 'react-native-smooth-clip-view';
import { scheduleOnRN, scheduleOnUI } from 'react-native-worklets';

const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window');

const CARD = {
  x: 32,
  y: SCREEN_HEIGHT - 260,
  width: SCREEN_WIDTH - 64,
  height: 180,
  radius: 20,
} as const;

const OPEN_MS = 350;
const DRAG_MS = 600;
const DRAG_TRANSLATE_Y = 180;
const CLOSE_MS = 400;
const CLOSE_KEYFRAME_COUNT = 31;

// progress 1 = fullscreen, 0 = card rect; ty shifts the clip downward the
// way the drag translation does in the reference overlay.
function presentationAt(progress: number, ty: number): SmoothClipPresentation {
  'worklet';
  const width = CARD.width + (SCREEN_WIDTH - CARD.width) * progress;
  const height = CARD.height + (SCREEN_HEIGHT - CARD.height) * progress;
  const x = CARD.x * (1 - progress);
  const y = CARD.y * (1 - progress) + ty;
  return {
    clip: { x, y, width, height, radius: CARD.radius },
    contentTranslateX: x,
    contentTranslateY: y,
  };
}

// Mirrors the reference overlay's close: ease-out cubic baked into the
// keyframe positions, translation decaying with the same progress channel.
function createCloseKeyframes(releaseTy: number) {
  'worklet';
  const frames = [];
  for (let index = 0; index < CLOSE_KEYFRAME_COUNT; index += 1) {
    const offset = index / (CLOSE_KEYFRAME_COUNT - 1);
    const inverse = 1 - offset;
    const closeProgress = inverse * inverse * inverse;
    frames.push({
      offset,
      presentation: presentationAt(closeProgress, releaseTy * closeProgress),
    });
  }
  return frames;
}

function HarnessOverlay({ onDone }: { onDone: () => void }) {
  const dispatchRef = useRef({ label: 'none', at: 0 });
  const markDispatch = useCallback((label: string, at: number) => {
    dispatchRef.current = { label, at };
    console.log(`[harness] dispatch label=${label} t=${at}`);
  }, []);
  const driver = useSmoothClipDriver(
    {
      clip: { ...CARD },
      contentTranslateX: CARD.x,
      contentTranslateY: CARD.y,
    },
    {
      onAnimationComplete: (result) => {
        const now = Date.now();
        const { label, at } = dispatchRef.current;
        console.log(
          `[harness] complete label=${label} finished=${result.finished} ` +
            `elapsed=${now - at}ms`
        );
        if (label === 'close') onDone();
      },
    }
  );
  const dragging = useSharedValue(0);
  const dragTy = useSharedValue(0);
  const openProgress = useSharedValue(0);

  useAnimatedReaction(
    () => (dragging.get() === 1 ? dragTy.get() : null),
    (ty) => {
      if (ty === null) return;
      const presentation = presentationAt(1, ty);
      driver.ui.setScalars(
        presentation.clip.x,
        presentation.clip.y,
        presentation.clip.width,
        presentation.clip.height,
        presentation.clip.radius,
        presentation.contentTranslateX,
        presentation.contentTranslateY
      );
    },
    [dragTy, dragging, driver]
  );

  useEffect(() => {
    const release = () => {
      'worklet';
      dragging.set(0);
      const releaseTy = dragTy.get();
      const frames = createCloseKeyframes(releaseTy);
      const target = frames[frames.length - 1]!.presentation;
      scheduleOnRN(markDispatch, 'close', Date.now());
      driver.ui.animateTo(target, {
        type: 'keyframes',
        duration: CLOSE_MS,
        frames,
        from: frames[0]!.presentation,
      });
    };
    const startDrag = () => {
      'worklet';
      driver.ui.beginInteraction();
      dragging.set(1);
      dragTy.set(0);
      dragTy.set(
        withTiming(
          DRAG_TRANSLATE_Y,
          { duration: DRAG_MS, easing: Easing.linear },
          (finished) => {
            if (finished) release();
          }
        )
      );
    };
    scheduleOnUI(() => {
      'worklet';
      scheduleOnRN(markDispatch, 'open', Date.now());
      driver.ui.animateTo(presentationAt(1, 0), {
        type: 'timing',
        duration: OPEN_MS,
        controlPoints: ClipEasings.easeOutCubic,
      });
      openProgress.set(
        withTiming(1, { duration: OPEN_MS }, (finished) => {
          if (finished) startDrag();
        })
      );
    });
  }, [dragTy, dragging, driver, markDispatch, openProgress]);

  return (
    <View pointerEvents="none" style={styles.overlay}>
      <SmoothClipView
        driver={driver}
        style={styles.host}
        testID="harness-clip-host"
      >
        <View style={styles.sheet}>
          <Text style={styles.sheetLabel}>Dismiss harness sheet</Text>
        </View>
      </SmoothClipView>
    </View>
  );
}

export function DismissHarness() {
  const [running, setRunning] = useState(false);
  const stop = useCallback(() => setRunning(false), []);
  return (
    <>
      <View style={styles.controls}>
        <Pressable
          accessibilityRole="button"
          onPress={() => setRunning(true)}
          style={({ pressed }) => [
            styles.runButton,
            pressed ? styles.runButtonPressed : null,
          ]}
          testID="harness-run"
        >
          <Text style={styles.runButtonText}>
            {running ? 'Cycle running…' : 'Run dismiss cycle'}
          </Text>
        </Pressable>
      </View>
      {running ? <HarnessOverlay onDone={stop} /> : null}
    </>
  );
}

const styles = StyleSheet.create({
  controls: {
    paddingHorizontal: 20,
    paddingTop: 12,
  },
  runButton: {
    alignItems: 'center',
    backgroundColor: '#8FE388',
    borderRadius: 14,
    paddingHorizontal: 22,
    paddingVertical: 12,
  },
  runButtonPressed: {
    opacity: 0.72,
  },
  runButtonText: {
    color: '#06121F',
    fontSize: 14,
    fontWeight: '800',
  },
  overlay: {
    position: 'absolute',
    top: 0,
    left: 0,
    width: SCREEN_WIDTH,
    height: SCREEN_HEIGHT,
    zIndex: 999,
  },
  host: {
    position: 'absolute',
    top: 0,
    left: 0,
    width: SCREEN_WIDTH,
    height: SCREEN_HEIGHT,
  },
  sheet: {
    flex: 1,
    backgroundColor: '#1E3A5F',
    alignItems: 'center',
    justifyContent: 'center',
  },
  sheetLabel: {
    color: '#E8F1FB',
    fontSize: 18,
    fontWeight: '600',
  },
});
