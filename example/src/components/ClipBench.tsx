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
  getSmoothClipCapabilities,
  SmoothClipView,
  useSmoothClipDriver,
  useSmoothClipGroupDriver,
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

// Long enough for two screenshot round trips inside one block.
const BLOCK_MS = 6000;

// Longer than BLOCK_MS so the native leg cannot end during a block.
const LEG_MS = BLOCK_MS + 2000;
const AUTONOMOUS_COMPLEX_PATH_ANIMATION =
  getSmoothClipCapabilities().autonomousComplexPathAnimation;

// Animated radius defeats integer-outline dedupe on every frame.
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

function complexPresentationAt(
  progress: number,
  mirrored = false
): SmoothClipPresentation {
  'worklet';
  const p = mirrored ? 1 - progress : progress;
  const inset = 18 + p * 30;
  return {
    clip: {
      x: inset,
      y: 120 + p * 80,
      width: SCREEN_WIDTH - inset * 2,
      height: 150 + p * 110,
      radius: 18,
      topLeftRadius: 18 + p * 40,
      topRightRadius: 42 - p * 20,
      bottomRightRadius: 12 + p * 46,
      bottomLeftRadius: 34 - p * 12,
      curve: 'continuous',
    },
    contentTranslateX: inset * 0.35,
    contentTranslateY: p * 28,
    contentScale: 0.92 + p * 0.08,
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

// Per-frame UI-runtime setScalars stream with no JS after mount.
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
      presentation.clip.radius,
      presentation.clip.radius,
      presentation.clip.radius,
      presentation.clip.curve === 'continuous' ? 1 : 0,
      presentation.contentTranslateX,
      presentation.contentTranslateY,
      presentation.contentScale ?? 1
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

// One worklet computes both presentations and commits them in a single
// native transaction. This is the correctness-first streaming path used by
// consumers before a motion plan is eligible for native ownership.
function BatchStreamBench() {
  const first = useSmoothClipDriver(complexPresentationAt(0));
  const second = useSmoothClipDriver(complexPresentationAt(0, true));
  const group = useSmoothClipGroupDriver();

  useFrameCallback((frameInfo) => {
    const phase = (frameInfo.timestamp % (2 * LEG_MS)) / (2 * LEG_MS);
    const progress = phase < 0.5 ? phase * 2 : (1 - phase) * 2;
    group.ui.setBatch([
      { driver: first, presentation: complexPresentationAt(progress) },
      {
        driver: second,
        presentation: complexPresentationAt(progress, true),
      },
    ]);
  });

  return (
    <View pointerEvents="none" style={styles.overlay}>
      <SmoothClipView driver={first} style={styles.host} testID="bench-batch-a">
        <BenchSheet label="setBatch · participant A" />
      </SmoothClipView>
      <SmoothClipView
        driver={second}
        style={styles.host}
        testID="bench-batch-b"
      >
        <BenchSheet label="setBatch · participant B" />
      </SmoothClipView>
    </View>
  );
}

type BenchController = Readonly<{ stop(): Promise<void> }>;

// Both hosts settle under one process-global native group ID. The parent
// awaits stop(), which finishes the native group before unmounting either
// host; teardown is therefore gated by the native leg itself.
function GroupedNativeBench({
  registerController,
}: {
  registerController(controller: BenchController | null): void;
}) {
  const first = useSmoothClipDriver(complexPresentationAt(0));
  const second = useSmoothClipDriver(complexPresentationAt(0, true));
  const aliveRef = useRef(true);
  const targetRef = useRef(1);
  const activeGroupIdRef = useRef(0);
  const pendingStartRef = useRef<Promise<void>>(Promise.resolve());

  const startLegRef = useRef<(target: number) => Promise<void>>(async () => {});
  const launchLegRef = useRef<(target: number) => void>(() => {});
  const group = useSmoothClipGroupDriver({
    onAnimationComplete: ({ finished }) => {
      if (!finished || !aliveRef.current) return;
      const target = 1 - targetRef.current;
      targetRef.current = target;
      launchLegRef.current(target);
    },
  });

  startLegRef.current = async (target: number) => {
    const groupId = await group.react.animateTo(
      [
        { driver: first, target: complexPresentationAt(target) },
        { driver: second, target: complexPresentationAt(target, true) },
      ],
      {
        type: 'timing',
        duration: LEG_MS,
        controlPoints: ClipEasings.easeOutCubic,
        suspensionPolicy: 'pause',
      }
    );
    activeGroupIdRef.current = groupId;
  };
  launchLegRef.current = (target: number) => {
    pendingStartRef.current = startLegRef.current(target).catch((error) => {
      logBench(`native group failed: ${String(error)}`);
    });
  };

  useEffect(() => {
    aliveRef.current = true;
    targetRef.current = 1;
    launchLegRef.current(1);
    registerController({
      async stop() {
        aliveRef.current = false;
        await pendingStartRef.current;
        const groupId = activeGroupIdRef.current;
        if (groupId > 0) await group.react.cancel(groupId, 'finish');
      },
    });
    return () => {
      aliveRef.current = false;
      registerController(null);
    };
  }, [group, registerController]);

  return (
    <View pointerEvents="none" style={styles.overlay}>
      <SmoothClipView driver={first} style={styles.host} testID="bench-group-a">
        <BenchSheet label="Native group · participant A" />
      </SmoothClipView>
      <SmoothClipView
        driver={second}
        style={styles.host}
        testID="bench-group-b"
      >
        <BenchSheet label="Native group · participant B" />
      </SmoothClipView>
    </View>
  );
}

// Naive overflow:hidden baseline; Fabric size changes pay layout each frame.
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

type BenchMode =
  'group-native' | 'batch-stream' | 'scalars-stream' | 'reanimated';

const MODES: ReadonlyArray<{ mode: BenchMode; label: string }> = [
  { mode: 'group-native', label: 'Grouped native settlement' },
  { mode: 'batch-stream', label: 'Atomic setBatch stream' },
  { mode: 'scalars-stream', label: 'setScalars stream' },
  { mode: 'reanimated', label: 'Naive Reanimated baseline' },
];

const BLOCK_HINT = Platform.select({
  ios:
    'Expected: a JS block never stalls any mode. A main block freezes the ' +
    'setScalars stream and the Reanimated baseline (the UI runtime lives on ' +
    'the main thread) but NOT a running native animateTo — the render ' +
    'server keeps animating it.',
  default:
    'Expected: a JS block never stalls any mode; a main block stalls all of ' +
    'them (Android animates views on the main thread).',
});

export function ClipBench() {
  const [running, setRunning] = useState<BenchMode | null>(null);
  const controllerRef = useRef<BenchController | null>(null);

  const registerController = useCallback(
    (controller: BenchController | null) => {
      controllerRef.current = controller;
    },
    []
  );

  const toggle = useCallback(
    async (mode: BenchMode) => {
      const current = running;
      if (current !== null) {
        await controllerRef.current?.stop();
        controllerRef.current = null;
      }
      setRunning(current === mode ? null : mode);
    },
    [running]
  );

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
            onPress={() => {
              toggle(mode).catch((error) => {
                logBench(`mode teardown failed: ${String(error)}`);
              });
            }}
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
      {running === 'group-native' ? (
        AUTONOMOUS_COMPLEX_PATH_ANIMATION ? (
          <GroupedNativeBench registerController={registerController} />
        ) : (
          <BatchStreamBench />
        )
      ) : null}
      {running === 'batch-stream' ? <BatchStreamBench /> : null}
      {running === 'scalars-stream' ? <ScalarsStreamBench /> : null}
      {running === 'reanimated' ? <ReanimatedBench /> : null}
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
