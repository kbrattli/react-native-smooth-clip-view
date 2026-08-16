import { useCallback, useEffect, useRef, useState } from 'react';
import {
  Dimensions,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import Animated, {
  Easing,
  useAnimatedStyle,
  useFrameCallback,
  useSharedValue,
  withRepeat,
  withTiming,
} from 'react-native-reanimated';
import {
  ClipEasings,
  SmoothClipView,
  useSmoothClipDriver,
  type SmoothClipPresentation,
} from 'react-native-smooth-clip-view';
import { scheduleOnRN, scheduleOnUI } from 'react-native-worklets';

const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window');

const CARD = {
  x: 32,
  y: SCREEN_HEIGHT - 280,
  width: SCREEN_WIDTH - 64,
  height: 200,
  radius: 24,
} as const;

// Long enough that two ~3s screenshot round-trips land INSIDE one block, so a
// moving (or frozen) clip across them is conclusive evidence.
const BLOCK_MS = 6000;

// One leg of the card↔fullscreen sweep. Strictly longer than BLOCK_MS so a
// block pressed at any moment lands entirely inside a running animation — the
// block buttons then demonstrate (not just claim) which thread each mode
// depends on. If a leg could end mid-block, the native mode's re-arm (which
// legitimately rides the blocked JS/main thread) would freeze the clip at the
// leg boundary and masquerade as a stalled animation.
const LEG_MS = BLOCK_MS + 2000;

// The radius animates too (card radius → 0 at fullscreen) on purpose: a
// changing radius defeats the integer-outline dedupe in SmoothClipView.kt, so
// every mode pays the worst-case invalidateOutline-per-frame cost and the
// comparison is not flattered by the pure-translation fast path.
function presentationAt(progress: number): SmoothClipPresentation {
  'worklet';
  const x = CARD.x * (1 - progress);
  const y = CARD.y * (1 - progress);
  return {
    clip: {
      x,
      y,
      width: CARD.width + (SCREEN_WIDTH - CARD.width) * progress,
      height: CARD.height + (SCREEN_HEIGHT - CARD.height) * progress,
      radius: CARD.radius * (1 - progress),
    },
    contentTranslateX: x,
    contentTranslateY: y,
  };
}

function logBench(message: string) {
  console.log(`[clip-bench] ${message}`);
}

function BenchSheet({ label }: { label: string }) {
  return (
    <View style={styles.sheet}>
      <Text style={styles.sheetLabel}>{label}</Text>
    </View>
  );
}

// Mode 1 — the open/close path: native timing animations ping-ponging
// card↔fullscreen. Each leg is dispatched from the UI runtime; the completion
// hop that re-arms the next leg rides the JS thread, so a JS block delays the
// turnaround but never the animation in flight.
function NativeAnimBench() {
  const nextTargetRef = useRef(0);
  const aliveRef = useRef(true);
  const driver = useSmoothClipDriver(
    {
      clip: { ...CARD },
      contentTranslateX: CARD.x,
      contentTranslateY: CARD.y,
    },
    {
      onAnimationComplete: (result) => {
        if (!result.finished || !aliveRef.current) return;
        const target = nextTargetRef.current;
        nextTargetRef.current = 1 - target;
        scheduleOnUI(() => {
          'worklet';
          driver.ui.animateTo(presentationAt(target), {
            type: 'timing',
            duration: LEG_MS,
            controlPoints: ClipEasings.easeOutCubic,
          });
        });
      },
    }
  );

  useEffect(() => {
    aliveRef.current = true;
    nextTargetRef.current = 0;
    scheduleOnUI(() => {
      'worklet';
      driver.ui.animateTo(presentationAt(1), {
        type: 'timing',
        duration: LEG_MS,
        controlPoints: ClipEasings.easeOutCubic,
      });
    });
    return () => {
      aliveRef.current = false;
    };
  }, [driver]);

  return (
    <View pointerEvents="none" style={styles.overlay}>
      <SmoothClipView driver={driver} style={styles.host} testID="bench-native">
        <BenchSheet label="Native animateTo" />
      </SmoothClipView>
    </View>
  );
}

// Mode 2 — the drag path: one driver.ui.setScalars per frame from a UI-runtime
// frame callback, sweeping a triangle wave. No JS involvement at all after
// mount, so this keeps streaming through a JS block.
function ScalarsStreamBench() {
  const driver = useSmoothClipDriver({
    clip: { ...CARD },
    contentTranslateX: CARD.x,
    contentTranslateY: CARD.y,
  });

  useFrameCallback((frameInfo) => {
    const phase = (frameInfo.timestamp % (2 * LEG_MS)) / (2 * LEG_MS);
    const progress = phase < 0.5 ? phase * 2 : (1 - phase) * 2;
    const presentation = presentationAt(progress);
    driver.ui.setScalars(
      presentation.clip.x,
      presentation.clip.y,
      presentation.clip.width,
      presentation.clip.height,
      presentation.clip.radius,
      presentation.contentTranslateX,
      presentation.contentTranslateY
    );
  });

  return (
    <View pointerEvents="none" style={styles.overlay}>
      <SmoothClipView
        driver={driver}
        style={styles.host}
        testID="bench-scalars"
      >
        <BenchSheet label="setScalars stream" />
      </SmoothClipView>
    </View>
  );
}

// Mode 3 — the naive baseline: what this screen would be without the library.
// An overflow:'hidden' Animated.View whose left/top/width/height/borderRadius
// animate via useAnimatedStyle. The content carries NO transform: inside a
// container already positioned at the clip origin, untransformed content has
// its top-left riding the clip — exactly what the library modes' fullscreen
// host + contentTranslate = clip origin renders, so the comparison is
// like-for-like (a counter-translation would pin the sheet to screen (0,0)
// and animate a mask-reveal the other modes don't). On Fabric the size
// channels are layout props, so every frame pays a ShadowTree commit + layout
// instead of RenderNode property writes.
function ReanimatedBench() {
  const progress = useSharedValue(0);

  useEffect(() => {
    progress.set(
      withRepeat(
        withTiming(1, {
          duration: LEG_MS,
          easing: Easing.out(Easing.cubic),
        }),
        -1,
        true
      )
    );
    return () => {
      progress.set(0);
    };
  }, [progress]);

  const clipStyle = useAnimatedStyle(() => {
    const presentation = presentationAt(progress.get());
    return {
      left: presentation.clip.x,
      top: presentation.clip.y,
      width: presentation.clip.width,
      height: presentation.clip.height,
      borderRadius: presentation.clip.radius,
    };
  });

  return (
    <View pointerEvents="none" style={styles.overlay}>
      <Animated.View style={[styles.reanimatedClip, clipStyle]}>
        <View style={styles.host}>
          <BenchSheet label="Reanimated overflow:hidden" />
        </View>
      </Animated.View>
    </View>
  );
}

// Tight-loop microbench: 10k setScalars calls in one UI task, reported as
// ns/call to logcat. Run once with velocityTracking on and once off — the
// whole loop shares one scheduling context, so the difference between the two
// isolates the velocity-sample cost that wall-clock section stats cannot
// resolve under emulator noise.
function MicroBench({
  onDone,
  velocityTracking,
}: {
  onDone: () => void;
  velocityTracking: boolean;
}) {
  const aliveRef = useRef(true);
  const driver = useSmoothClipDriver(
    {
      clip: { ...CARD },
      contentTranslateX: CARD.x,
      contentTranslateY: CARD.y,
    },
    { velocityTracking }
  );

  useEffect(() => {
    aliveRef.current = true;
    const finish = (message: string) => {
      // clearTimeout below cannot cancel a worklet already queued on the UI
      // runtime; guard here so a stale run can neither log a bogus ns/call
      // measured against a disposed driver's no-op writes nor setRunning(null)
      // over a mode the user has since started.
      if (!aliveRef.current) return;
      logBench(message);
      onDone();
    };
    const timer = setTimeout(() => {
      scheduleOnUI(() => {
        'worklet';
        const globals = globalThis as unknown as {
          _getAnimationTimestamp: () => number;
        };
        const a = presentationAt(1);
        const b = presentationAt(0.9);
        const apply = (p: SmoothClipPresentation) => {
          driver.ui.setScalars(
            p.clip.x,
            p.clip.y,
            p.clip.width,
            p.clip.height,
            p.clip.radius,
            p.contentTranslateX,
            p.contentTranslateY
          );
        };
        const ITERATIONS = 10000;
        for (let index = 0; index < 500; index += 1) {
          apply(index % 2 === 0 ? a : b);
        }
        const start = globals._getAnimationTimestamp();
        for (let index = 0; index < ITERATIONS; index += 1) {
          apply(index % 2 === 0 ? a : b);
        }
        const end = globals._getAnimationTimestamp();
        scheduleOnRN(
          finish,
          `ubench velocityTracking=${velocityTracking} ` +
            `iterations=${ITERATIONS} ` +
            `alternating=${Math.round(((end - start) / ITERATIONS) * 1e6)}ns/call`
        );
      });
    }, 300);
    return () => {
      aliveRef.current = false;
      clearTimeout(timer);
    };
  }, [driver, onDone, velocityTracking]);

  return (
    <View pointerEvents="none" style={styles.overlay}>
      <SmoothClipView driver={driver} style={styles.host} testID="bench-micro">
        <BenchSheet label="setScalars µbench" />
      </SmoothClipView>
    </View>
  );
}

type BenchMode =
  'native-anim' | 'scalars-stream' | 'reanimated' | 'ubench-off' | 'ubench-on';

const MODES: ReadonlyArray<{ mode: BenchMode; label: string }> = [
  { mode: 'native-anim', label: 'Native animateTo loop' },
  { mode: 'scalars-stream', label: 'setScalars stream (drag path)' },
  { mode: 'reanimated', label: 'Naive Reanimated baseline' },
  { mode: 'ubench-off', label: 'setScalars µbench (tracking off)' },
  { mode: 'ubench-on', label: 'setScalars µbench (tracking on)' },
];

// A JS block never stalls any mode on either platform (no JS on the frame
// path). A main block diverges: Android's frame loop and View writes are
// main-thread-only, so everything stalls together; iOS's render server keeps
// advancing installed Core Animations, so only the modes driven from the
// main-thread UI runtime (setScalars stream, Reanimated baseline) freeze.
const BLOCK_HINT = Platform.select({
  ios:
    'Expected: a JS block never stalls any mode. A main block freezes the ' +
    'setScalars stream and the Reanimated baseline (the UI runtime lives on ' +
    'the main thread) but NOT a running native animateTo — the render ' +
    'server keeps animating it. The two µbench modes measure identical ' +
    'native code here (velocityTracking is Android-only); run them on ' +
    'Android for a meaningful on/off delta.',
  default:
    'Watch logcat tag SmoothClipTrace for per-call stats (debug builds). ' +
    'Expected: a JS block never stalls any mode; a main block stalls all of ' +
    'them (Android animates views on the main thread).',
});

export function ClipBench() {
  const [running, setRunning] = useState<BenchMode | null>(null);

  const toggle = useCallback((mode: BenchMode) => {
    setRunning((current) => (current === mode ? null : mode));
  }, []);

  const stopRunning = useCallback(() => setRunning(null), []);

  const blockJsThread = useCallback(() => {
    logBench(`js block begin t=${Date.now()}`);
    const start = Date.now();
    while (Date.now() - start < BLOCK_MS) {
      // busy-wait: hold the JS thread hostage
    }
    logBench(`js block end t=${Date.now()}`);
  }, []);

  const blockMainThread = useCallback(() => {
    scheduleOnUI(() => {
      'worklet';
      const globals = globalThis as unknown as {
        _getAnimationTimestamp: () => number;
      };
      const begin = globals._getAnimationTimestamp();
      scheduleOnRN(logBench, `main block begin t=${Date.now()}`);
      while (globals._getAnimationTimestamp() - begin < BLOCK_MS) {
        // busy-wait: hold the main thread hostage
      }
      scheduleOnRN(logBench, `main block end t=${Date.now()}`);
    });
  }, []);

  return (
    <>
      <View style={styles.controls}>
        {MODES.map(({ mode, label }) => (
          <Pressable
            accessibilityRole="button"
            key={mode}
            onPress={() => toggle(mode)}
            style={({ pressed }) => [
              styles.modeButton,
              running === mode ? styles.modeButtonActive : null,
              pressed ? styles.buttonPressed : null,
            ]}
            testID={`clip-bench-${mode}`}
          >
            <Text style={styles.modeButtonText}>
              {running === mode ? `Stop: ${label}` : label}
            </Text>
          </Pressable>
        ))}
        <View style={styles.blockRow}>
          <Pressable
            accessibilityRole="button"
            onPress={blockJsThread}
            style={({ pressed }) => [
              styles.blockButton,
              pressed ? styles.buttonPressed : null,
            ]}
            testID="clip-bench-block-js"
          >
            <Text style={styles.blockButtonText}>
              {`Block JS ${BLOCK_MS / 1000}s`}
            </Text>
          </Pressable>
          <Pressable
            accessibilityRole="button"
            onPress={blockMainThread}
            style={({ pressed }) => [
              styles.blockButton,
              pressed ? styles.buttonPressed : null,
            ]}
            testID="clip-bench-block-main"
          >
            <Text style={styles.blockButtonText}>
              {`Block main ${BLOCK_MS / 1000}s`}
            </Text>
          </Pressable>
        </View>
        <Text style={styles.hint}>{BLOCK_HINT}</Text>
      </View>
      {running === 'native-anim' ? <NativeAnimBench /> : null}
      {running === 'scalars-stream' ? <ScalarsStreamBench /> : null}
      {running === 'reanimated' ? <ReanimatedBench /> : null}
      {running === 'ubench-off' ? (
        <MicroBench onDone={stopRunning} velocityTracking={false} />
      ) : null}
      {running === 'ubench-on' ? (
        <MicroBench onDone={stopRunning} velocityTracking />
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
  modeButton: {
    alignItems: 'center',
    backgroundColor: '#66E3FF',
    borderRadius: 14,
    paddingHorizontal: 22,
    paddingVertical: 12,
  },
  modeButtonActive: {
    backgroundColor: '#F2A65A',
  },
  buttonPressed: {
    opacity: 0.72,
  },
  modeButtonText: {
    color: '#06121F',
    fontSize: 14,
    fontWeight: '800',
  },
  blockRow: {
    flexDirection: 'row',
    gap: 8,
  },
  blockButton: {
    alignItems: 'center',
    backgroundColor: '#E36C6C',
    borderRadius: 14,
    flex: 1,
    paddingVertical: 12,
  },
  blockButtonText: {
    color: '#06121F',
    fontSize: 14,
    fontWeight: '800',
  },
  hint: {
    color: '#8FA6BF',
    fontSize: 12,
    lineHeight: 17,
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
  reanimatedClip: {
    overflow: 'hidden',
    position: 'absolute',
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
