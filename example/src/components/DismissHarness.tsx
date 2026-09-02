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
  type SmoothClipCompletion,
  type SmoothClipPresentation,
  SmoothClipView,
  useSmoothClipController,
} from 'react-native-smooth-clip-view';
import { scheduleOnRN, scheduleOnUI } from 'react-native-worklets';
import { completeAfterNativeLandingWithValue } from '../completeAfterNativeLanding';

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
const CLOSE_COMPLETION_TAG = 1;
// How the close is dispatched and what runs beside it. 'timing-stall'
// blocks the MAIN thread for 500 ms mid-close to prove the animation rides the
// render server; 'bench' skips the cycle and times frame calls.
export type HarnessMode = 'timing' | 'timing-stall' | 'bench';

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

function logHarness(message: string) {
  console.log(`[harness] ${message}`);
}

function HarnessOverlay({
  mode,
  onDone,
}: {
  mode: Exclude<HarnessMode, 'bench'>;
  onDone: () => void;
}) {
  const dispatchRef = useRef({ label: 'none', at: 0 });
  const markDispatch = useCallback((label: string, at: number) => {
    dispatchRef.current = { label, at };
    console.log(`[harness] dispatch label=${label} t=${at}`);
  }, []);
  const dragging = useSharedValue(0);
  const dragTy = useSharedValue(0);
  const openProgress = useSharedValue(0);

  const completeClose = useCallback(
    (finished: boolean) => {
      const { label, at } = dispatchRef.current;
      logHarness(
        `complete label=${label} finished=${finished} elapsed=${Date.now() - at}ms`
      );
      onDone();
    },
    [onDone]
  );
  const onNativeAnimationComplete = useCallback(
    (result: SmoothClipCompletion) => {
      if (result.completionTag === CLOSE_COMPLETION_TAG) {
        completeAfterNativeLandingWithValue(completeClose, result.finished);
      }
    },
    [completeClose]
  );
  const clip = useSmoothClipController(
    {
      clip: { ...CARD },
      contentTranslateX: CARD.x,
      contentTranslateY: CARD.y,
    },
    { onAnimationComplete: onNativeAnimationComplete }
  );

  // Blocks the MAIN thread (the worklets UI runtime runs inline on main on
  // iOS) 100 ms into the close, for 500 ms of a 400 ms animation. A
  // render-server animation keeps moving; only the didStop callback — and with
  // it the logged elapsed — lands late.
  const stallTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const armMainThreadStall = useCallback(() => {
    stallTimerRef.current = setTimeout(() => {
      logHarness(`stall arm t=${Date.now()}`);
      scheduleOnUI(() => {
        'worklet';
        const globals = globalThis as unknown as {
          _getAnimationTimestamp: () => number;
        };
        const begin = globals._getAnimationTimestamp();
        scheduleOnRN(logHarness, `stall begin t=${Date.now()}`);
        while (globals._getAnimationTimestamp() - begin < 500) {
          // busy-wait: hold the main thread hostage mid-close
        }
        scheduleOnRN(logHarness, `stall end t=${Date.now()}`);
      });
    }, 100);
  }, []);

  // An armed stall must die with the harness: unmounting inside the 100 ms
  // window would otherwise still block the main thread for 500 ms later.
  useEffect(
    () => () => {
      if (stallTimerRef.current !== null) clearTimeout(stallTimerRef.current);
    },
    []
  );

  useAnimatedReaction(
    () => (dragging.get() === 1 ? dragTy.get() : null),
    (ty) => {
      if (ty === null) return;
      const presentation = presentationAt(1, ty);
      clip.ui.setFrame(presentation);
    },
    [clip, dragTy, dragging]
  );

  useEffect(() => {
    const release = () => {
      'worklet';
      dragging.set(0);
      const releaseTy = dragTy.get();
      const label = `close-${mode}`;
      const startedAt = Date.now();
      scheduleOnRN(markDispatch, label, startedAt);
      clip.ui.setFrame(presentationAt(1, releaseTy));
      clip.ui.beginInteraction();
      const run = clip.ui.animateTo(
        presentationAt(0, 0),
        {
          type: 'timing',
          duration: CLOSE_MS,
          controlPoints: ClipEasings.easeOutCubic,
        },
        CLOSE_COMPLETION_TAG
      );
      if (run === null) scheduleOnRN(completeClose, false);
      if (mode === 'timing-stall') {
        scheduleOnRN(armMainThreadStall);
      }
    };
    const startDrag = () => {
      'worklet';
      clip.ui.beginInteraction();
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
      clip.ui.animateTo(presentationAt(1, 0), {
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
  }, [
    armMainThreadStall,
    completeClose,
    dragTy,
    dragging,
    clip,
    markDispatch,
    mode,
    openProgress,
  ]);

  return (
    <View pointerEvents="none" style={styles.overlay}>
      <SmoothClipView
        controller={clip}
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

// Times controller.ui.setFrame on the UI runtime against a mounted host:
// alternating values that differ on every animated channel except the
// constant radius — position, bounds, and content translation all move, so
// each call lands live CALayer writes — vs a repeated value (the dedupe fast
// path). Logged as ns/call. Caveat: the whole run is one UI task, so the
// numbers cover the JSI + registry + property-write path and exclude the
// CATransaction commit that a real per-frame stream would also pay.
function BenchProbe({ onDone }: { onDone: () => void }) {
  const clip = useSmoothClipController({
    clip: { ...CARD },
    contentTranslateX: CARD.x,
    contentTranslateY: CARD.y,
  });

  useEffect(() => {
    const finish = (message: string) => {
      logHarness(message);
      onDone();
    };
    const timer = setTimeout(() => {
      scheduleOnUI(() => {
        'worklet';
        const globals = globalThis as unknown as {
          _getAnimationTimestamp: () => number;
        };
        // Distinct progress AND ty so x, y, width, height and both content
        // translations all change between a and b (only radius is constant in
        // presentationAt) — the alternating loop must exercise the full write
        // fan-out, not just the position channels.
        const a = presentationAt(1, 0);
        const b = presentationAt(0.9, 40);
        const apply = (p: SmoothClipPresentation) => {
          clip.ui.setFrame(p);
        };
        const ITERATIONS = 10000;
        for (let index = 0; index < 500; index += 1) {
          apply(index % 2 === 0 ? a : b);
        }
        const alternatingStart = globals._getAnimationTimestamp();
        for (let index = 0; index < ITERATIONS; index += 1) {
          apply(index % 2 === 0 ? a : b);
        }
        const alternatingEnd = globals._getAnimationTimestamp();
        // Prime with one untimed write so every timed call below is a true
        // dedupe (the alternating loop ends on b).
        apply(a);
        const dedupedStart = globals._getAnimationTimestamp();
        for (let index = 0; index < ITERATIONS; index += 1) {
          apply(a);
        }
        const dedupedEnd = globals._getAnimationTimestamp();
        const perCallNs = (spanMs: number) =>
          Math.round((spanMs / ITERATIONS) * 1e6);
        scheduleOnRN(
          finish,
          `bench iterations=${ITERATIONS} ` +
            `alternating=${perCallNs(alternatingEnd - alternatingStart)}ns/call ` +
            `deduped=${perCallNs(dedupedEnd - dedupedStart)}ns/call`
        );
      });
    }, 300);
    return () => clearTimeout(timer);
  }, [clip, onDone]);

  return (
    <View pointerEvents="none" style={styles.overlay}>
      <SmoothClipView controller={clip} style={styles.host} testID="bench-host">
        <View style={styles.sheet}>
          <Text style={styles.sheetLabel}>setFrame bench</Text>
        </View>
      </SmoothClipView>
    </View>
  );
}

const MODES: ReadonlyArray<{ mode: HarnessMode; label: string }> = [
  { mode: 'timing', label: 'Close: timing' },
  { mode: 'timing-stall', label: 'Close: timing + main stall' },
  { mode: 'bench', label: 'setFrame bench' },
];

export function DismissHarness() {
  const [running, setRunning] = useState<HarnessMode | null>(null);
  const stop = useCallback(() => setRunning(null), []);
  return (
    <>
      <View style={styles.controls}>
        {MODES.map(({ mode, label }) => (
          <Pressable
            accessibilityRole="button"
            key={mode}
            onPress={() => setRunning(mode)}
            style={({ pressed }) => [
              styles.runButton,
              pressed ? styles.runButtonPressed : null,
            ]}
            testID={`harness-run-${mode}`}
          >
            <Text style={styles.runButtonText}>
              {running === mode ? 'Running…' : label}
            </Text>
          </Pressable>
        ))}
      </View>
      {running === 'bench' ? <BenchProbe onDone={stop} /> : null}
      {running !== null && running !== 'bench' ? (
        <HarnessOverlay mode={running} onDone={stop} />
      ) : null}
    </>
  );
}

const styles = StyleSheet.create({
  controls: {
    gap: 8,
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
