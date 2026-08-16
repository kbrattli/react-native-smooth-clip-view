import { beforeEach, describe, expect, it, jest } from '@jest/globals';
import type { SmoothClipPresentation } from '../geometry';

let mockRNRuntime = false;
// The suite defaults to Android because the start-stamp tests below pin the
// Android frame-clock anchor; the iOS test re-imports the module under 'ios'.
// `var` + fallback because the hoisted module imports (and with them the
// mocked Platform.OS read) run before any initializer in this file.

var mockPlatformOS: string | undefined;

jest.mock('react-native', () => ({
  Platform: {
    get OS() {
      return mockPlatformOS ?? 'android';
    },
  },
}));

function mockUIState() {
  return globalThis as {
    __smoothClipTestQueueUI?: boolean;
    __smoothClipTestUITasks?: Array<() => void>;
  };
}

function mockMakeSharedValue<T>(initial: T) {
  const listeners = new Map<number, (value: T) => void>();
  return {
    _value: initial,
    get value(): T {
      return this._value;
    },
    set value(next: T) {
      this._value = next;
      listeners.forEach((listener) => listener(next));
    },
    addListener(id: number, listener: (value: T) => void) {
      listeners.set(id, listener);
    },
    removeListener(id: number) {
      listeners.delete(id);
    },
  };
}

type MockEffect = {
  effect: () => (() => void) | void;
  cleanup: (() => void) | void;
};
const mockEffects: MockEffect[] = [];

jest.mock('react', () => {
  const actual = jest.requireActual<typeof import('react')>('react');
  return {
    ...actual,
    useEffect: (effect: () => (() => void) | void) => {
      mockEffects.push({ effect, cleanup: effect() });
    },
    useRef: (initial: unknown) => ({ current: initial }),
  };
});

jest.mock('react-native-reanimated', () => ({
  useSharedValue: (initial: unknown) => mockMakeSharedValue(initial),
}));

jest.mock('react-native-worklets', () => ({
  isRNRuntime: () => mockRNRuntime,
  scheduleOnUI: (fn: (...args: never[]) => void, ...args: never[]) => {
    const task = () => fn(...args);
    const state = mockUIState();
    if (state.__smoothClipTestQueueUI) {
      (state.__smoothClipTestUITasks ??= []).push(task);
    } else {
      task();
    }
  },
  scheduleOnRN: (fn: (...args: never[]) => void, ...args: never[]) =>
    fn(...args),
}));

jest.mock('../smoothClipNative', () => ({
  __esModule: true,
  default: {
    setClipPresentation: jest.fn(),
    beginInteraction: jest.fn(() => [0, 0, 100, 80, 12, -4, -8]),
    animateTiming: jest.fn(() => 7),
    animateSpring: jest.fn(() => 8),
    animateKeyframes: jest.fn(() => 9),
    rejectAnimation: jest.fn(() => 99),
    cancelAnimation: jest.fn(() => [1, 0, 0, 100, 80, 12, -4, -8]),
    destroyDriver: jest.fn(),
    onClipAnimationComplete: jest.fn(() => ({ remove: jest.fn() })),
  },
}));

import { useSmoothClipDriver } from '../drivers.native';
import mockNativeModule from '../smoothClipNative';

type MockNative = {
  setClipPresentation: jest.Mock;
  beginInteraction: jest.Mock;
  animateTiming: jest.Mock;
  animateSpring: jest.Mock;
  animateKeyframes: jest.Mock;
  rejectAnimation: jest.Mock;
  cancelAnimation: jest.Mock;
  destroyDriver: jest.Mock;
  onClipAnimationComplete: jest.Mock;
};

const mockNative = mockNativeModule as unknown as MockNative;

const initial: SmoothClipPresentation = {
  clip: { x: 0, y: 0, width: 100, height: 80, radius: 12 },
  contentTranslateX: -4,
  contentTranslateY: -8,
};

const target: SmoothClipPresentation = {
  clip: { x: 10, y: 20, width: 200, height: 160, radius: 24 },
  contentTranslateX: -10,
  contentTranslateY: -20,
};

const timing = {
  type: 'timing' as const,
  duration: 250,
  controlPoints: [0.42, 0, 0.58, 1] as const,
};

const fromPresentation: SmoothClipPresentation = {
  clip: { x: 2, y: 4, width: 60, height: 50, radius: 8 },
  contentTranslateX: 1,
  contentTranslateY: 3,
};

describe('hybrid native driver (iOS + Android)', () => {
  beforeEach(() => {
    mockRNRuntime = false;
    mockPlatformOS = 'android';
    mockUIState().__smoothClipTestQueueUI = false;
    mockUIState().__smoothClipTestUITasks = [];
    mockEffects.length = 0;
    delete (globalThis as { __frameTimestamp?: number }).__frameTimestamp;
    delete (
      globalThis as {
        _getAnimationTimestamp?: () => number;
      }
    )._getAnimationTimestamp;
    jest.clearAllMocks();
    mockNative.animateTiming.mockReturnValue(7);
    mockNative.animateSpring.mockReturnValue(8);
    mockNative.animateKeyframes.mockReturnValue(9);
    mockNative.rejectAnimation.mockReturnValue(99);
  });

  it('fans interactive presentation writes out to native', () => {
    const driver = useSmoothClipDriver(initial);
    driver.presentation.value = target;

    expect(mockNative.setClipPresentation).toHaveBeenCalledWith(
      expect.any(Number),
      target.clip.x,
      target.clip.y,
      target.clip.width,
      target.clip.height,
      target.clip.radius,
      target.contentTranslateX,
      target.contentTranslateY,
      false,
      false
    );
  });

  it('setScalars writes native directly without touching presentation', () => {
    const driver = useSmoothClipDriver(initial);

    driver.ui.setScalars(1, 2, 3, 4, 5, 6, 7);

    expect(mockNative.setClipPresentation).toHaveBeenCalledWith(
      expect.any(Number),
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      true,
      false,
      false
    );
    // The SharedValue intentionally stays stale on the hot path.
    expect(driver.presentation.value).toBe(initial);
  });

  it('setScalars records velocity samples when velocityTracking is on', () => {
    const driver = useSmoothClipDriver(initial, { velocityTracking: true });

    driver.ui.setScalars(1, 2, 3, 4, 5, 6, 7);

    expect(mockNative.setClipPresentation).toHaveBeenLastCalledWith(
      expect.any(Number),
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      true,
      false,
      true
    );
  });

  it('set() always records velocity samples', () => {
    // Only the setScalars hot path is gated by velocityTracking; set() pays
    // full validation and a SharedValue seed per call already.
    const driver = useSmoothClipDriver(initial);

    driver.ui.set(target);

    expect(mockNative.setClipPresentation).toHaveBeenLastCalledWith(
      expect.any(Number),
      target.clip.x,
      target.clip.y,
      target.clip.width,
      target.clip.height,
      target.clip.radius,
      target.contentTranslateX,
      target.contentTranslateY,
      true,
      false
    );
  });

  it('always records the fused from seed, even without velocityTracking', () => {
    // One write per animateTo, not the per-frame stream the flag gates. An
    // unrecorded seed would invalidate the history a set()-driven drag just
    // recorded and break its 'inherit' handoff.
    const driver = useSmoothClipDriver(initial);

    driver.ui.animateTo(target, { ...timing, from: fromPresentation });

    expect(mockNative.setClipPresentation).toHaveBeenLastCalledWith(
      expect.any(Number),
      2,
      4,
      60,
      50,
      8,
      1,
      3,
      true,
      true,
      true
    );
  });

  it('treats a non-finite setScalars write as a full no-op', () => {
    const driver = useSmoothClipDriver(initial);
    const driverId = mockNative.setClipPresentation.mock
      .calls[0]?.[0] as number;
    const completionListener = mockNative.onClipAnimationComplete.mock
      .calls[0]?.[0] as (result: {
      driverId: number;
      animationId: number;
      finished: boolean;
    }) => void;
    const animationId = driver.ui.animateTo(target, timing);

    jest.clearAllMocks();
    driver.ui.setScalars(1, 2, Number.NaN, 4, 5, 6, 7);
    driver.ui.setScalars(1, 2, 3, 4, Number.POSITIVE_INFINITY, 6, 7);
    // Non-number types too: arithmetic would coerce these past a fused
    // (v - v) gate and into a UI-runtime throw from the binding's asNumber,
    // so the gate must reject on type, not just on finiteness.
    driver.ui.setScalars('3' as unknown as number, 2, 3, 4, 5, 6, 7);
    driver.ui.setScalars(1, true as unknown as number, 3, 4, 5, 6, 7);
    driver.ui.setScalars(1, 2, null as unknown as number, 4, 5, 6, 7);
    // Dropped on this side of the bridge (native re-validates anyway)...
    expect(mockNative.setClipPresentation).not.toHaveBeenCalled();

    // ...and without flipping ownership: a declarative write during the still
    // running animation must stay dropped-and-eligible, not be recorded as
    // native-observed and then swallowed by the dedupe cache for good.
    const dragged: SmoothClipPresentation = {
      clip: { x: 1, y: 2, width: 90, height: 70, radius: 10 },
      contentTranslateX: 0,
      contentTranslateY: 0,
    };
    driver.presentation.value = dragged;
    expect(mockNative.setClipPresentation).not.toHaveBeenCalled();

    // The completion still matches the untouched active id, releases
    // ownership, and the same value then fans out.
    completionListener({ driverId, animationId, finished: true });
    driver.presentation.value = {
      clip: { ...dragged.clip },
      contentTranslateX: 0,
      contentTranslateY: 0,
    };
    expect(mockNative.setClipPresentation).toHaveBeenCalledWith(
      driverId,
      1,
      2,
      90,
      70,
      10,
      0,
      0,
      false,
      false
    );
  });

  it('restores interactive ownership when native rejects a transition', () => {
    mockNative.animateTiming.mockReturnValueOnce(0);
    const driver = useSmoothClipDriver(initial);

    const animationId = driver.ui.animateTo(target, timing);

    // A native rejection funnels through rejectAnimation so exactly one
    // finished:false completion is emitted for the call.
    expect(animationId).toBe(99);
    expect(mockNative.rejectAnimation).toHaveBeenCalled();
    expect(driver.presentation.value).toBe(initial);

    // The listener must not be stuck: a later write still fans out.
    jest.clearAllMocks();
    driver.presentation.value = target;
    expect(mockNative.setClipPresentation).toHaveBeenCalledWith(
      expect.any(Number),
      target.clip.x,
      target.clip.y,
      target.clip.width,
      target.clip.height,
      target.clip.radius,
      target.contentTranslateX,
      target.contentTranslateY,
      false,
      false
    );
  });

  it('rejects invalid animations through rejectAnimation', () => {
    const driver = useSmoothClipDriver(initial);
    const animationId = driver.ui.animateTo(
      {
        clip: { x: 0, y: 0, width: Number.NaN, height: 1, radius: 0 },
        contentTranslateX: 0,
        contentTranslateY: 0,
      },
      timing
    );

    expect(animationId).toBe(99);
    expect(mockNative.rejectAnimation).toHaveBeenCalled();
    expect(mockNative.animateTiming).not.toHaveBeenCalled();
  });

  it('rejects an unrecognized animation type before any side effect', () => {
    const driver = useSmoothClipDriver(initial);
    jest.clearAllMocks();
    mockNative.rejectAnimation.mockReturnValue(99);

    // Only reachable from untyped JS, but the contract must hold there too:
    // an unknown type skips the keyframe flatten, so letting it through the
    // gate would hot-write `from` and then hand native a null frames array.
    const animationId = driver.ui.animateTo(target, {
      type: 'Keyframes',
      duration: 300,
      frames: [
        { offset: 0, presentation: fromPresentation },
        { offset: 1, presentation: target },
      ],
      from: fromPresentation,
    } as never);

    expect(animationId).toBe(99);
    expect(mockNative.rejectAnimation).toHaveBeenCalled();
    expect(mockNative.setClipPresentation).not.toHaveBeenCalled();
    expect(mockNative.animateKeyframes).not.toHaveBeenCalled();
  });

  it('throws when ui controls are invoked on the RN runtime', () => {
    mockRNRuntime = true;
    const driver = useSmoothClipDriver(initial);

    expect(() => driver.ui.set(target)).toThrow();
    expect(() => driver.ui.setScalars(1, 2, 3, 4, 5, 6, 7)).toThrow();
    expect(() => driver.ui.beginInteraction()).toThrow();
  });

  it('react.animateTo resolves with the native animation id', async () => {
    mockRNRuntime = true;
    const driver = useSmoothClipDriver(initial);

    await expect(driver.react.animateTo(target, timing)).resolves.toBe(7);
    expect(mockNative.animateTiming).toHaveBeenCalled();
  });

  it('react.cancel resolves with the native presentation', async () => {
    mockRNRuntime = true;
    const driver = useSmoothClipDriver(initial);

    const result = await driver.react.cancel();
    expect(result).toEqual({
      clip: { x: 0, y: 0, width: 100, height: 80, radius: 12 },
      contentTranslateX: -4,
      contentTranslateY: -8,
    });
  });

  it('treats only the numeric 1 as a handled cancel flag', () => {
    const driver = useSmoothClipDriver(initial);
    driver.ui.animateTo(target, timing);

    // A jsi boolean from native must not count as handled — this pins the
    // native contract (iOS and Android both emit 1.0/0.0).
    mockNative.cancelAnimation.mockReturnValueOnce([
      true,
      5,
      6,
      50,
      40,
      8,
      0,
      0,
    ]);
    expect(driver.ui.cancel()).toEqual(target);

    driver.ui.animateTo(target, timing);
    mockNative.cancelAnimation.mockReturnValueOnce([1, 5, 6, 50, 40, 8, 0, 0]);
    const result = driver.ui.cancel();
    expect(result).toEqual({
      clip: { x: 5, y: 6, width: 50, height: 40, radius: 8 },
      contentTranslateX: 0,
      contentTranslateY: 0,
    });

    // Ownership is interactive again: the next distinct write fans out.
    jest.clearAllMocks();
    driver.presentation.value = target;
    expect(mockNative.setClipPresentation).toHaveBeenCalled();
  });

  it('recovers after an unfinished completion and re-delivers dropped values', () => {
    const onAnimationComplete = jest.fn();
    const driver = useSmoothClipDriver(initial, { onAnimationComplete });
    const driverId = mockNative.setClipPresentation.mock
      .calls[0]?.[0] as number;
    const completionListener = mockNative.onClipAnimationComplete.mock
      .calls[0]?.[0] as (result: {
      driverId: number;
      animationId: number;
      finished: boolean;
    }) => void;

    const animationId = driver.ui.animateTo(target, timing);

    // Values written during native ownership are dropped...
    jest.clearAllMocks();
    const dragged: SmoothClipPresentation = {
      clip: { x: 1, y: 2, width: 90, height: 70, radius: 10 },
      contentTranslateX: 0,
      contentTranslateY: 0,
    };
    driver.presentation.value = dragged;
    expect(mockNative.setClipPresentation).not.toHaveBeenCalled();

    // ...an involuntary stop (participant unmount, stripped animation) must
    // still release ownership and deliver its callback...
    completionListener({ driverId, animationId, finished: false });
    expect(onAnimationComplete).toHaveBeenCalledWith({
      animationId,
      finished: false,
    });

    // ...and the dropped value must not be swallowed by the dedupe cache.
    driver.presentation.value = {
      clip: { ...dragged.clip },
      contentTranslateX: 0,
      contentTranslateY: 0,
    };
    expect(mockNative.setClipPresentation).toHaveBeenCalledWith(
      driverId,
      dragged.clip.x,
      dragged.clip.y,
      dragged.clip.width,
      dragged.clip.height,
      dragged.clip.radius,
      dragged.contentTranslateX,
      dragged.contentTranslateY,
      false,
      false
    );
  });

  it('survives an effect replay and revives the destroyed native driver', () => {
    const driver = useSmoothClipDriver(initial);
    const registration = mockEffects[mockEffects.length - 1]!;

    // Cleanup must clear UI-side Native ownership as well as native state.
    driver.ui.animateTo(target, timing);

    // StrictMode / <Activity>: cleanup runs, then the same effect re-runs.
    if (typeof registration.cleanup === 'function') registration.cleanup();
    expect(mockNative.destroyDriver).toHaveBeenCalled();

    jest.clearAllMocks();
    expect(() => registration.effect()).not.toThrow();

    // The replay re-seeds native with a take-ownership write...
    expect(mockNative.setClipPresentation).toHaveBeenCalledWith(
      expect.any(Number),
      target.clip.x,
      target.clip.y,
      target.clip.width,
      target.clip.height,
      target.clip.radius,
      target.contentTranslateX,
      target.contentTranslateY,
      true,
      false
    );

    // ...and the driver remains fully operational afterwards.
    driver.presentation.value = initial;
    expect(mockNative.setClipPresentation).toHaveBeenCalledWith(
      expect.any(Number),
      initial.clip.x,
      initial.clip.y,
      initial.clip.width,
      initial.clip.height,
      initial.clip.radius,
      initial.contentTranslateX,
      initial.contentTranslateY,
      false,
      false
    );
  });

  it('ignores a delayed completion from the previous native incarnation', () => {
    mockNative.animateTiming.mockReturnValueOnce(41).mockReturnValueOnce(42);
    const driver = useSmoothClipDriver(initial);
    const registration = mockEffects[mockEffects.length - 1]!;
    const oldId = driver.ui.animateTo(target, timing);
    expect(oldId).toBe(41);

    if (typeof registration.cleanup === 'function') registration.cleanup();
    registration.effect();
    const completionListener = mockNative.onClipAnimationComplete.mock.calls.at(
      -1
    )?.[0] as (result: {
      driverId: number;
      animationId: number;
      finished: boolean;
    }) => void;
    const driverId = mockNative.setClipPresentation.mock.calls.at(-1)?.[0] as
      number | undefined;
    expect(driverId).toBeDefined();
    const newId = driver.ui.animateTo(fromPresentation, timing);
    expect(newId).toBe(42);

    completionListener({
      driverId: driverId!,
      animationId: oldId,
      finished: false,
    });
    jest.clearAllMocks();
    driver.presentation.value = initial;
    // Old id 41 must not release Native ownership held by id 42.
    expect(mockNative.setClipPresentation).not.toHaveBeenCalled();

    completionListener({
      driverId: driverId!,
      animationId: newId,
      finished: true,
    });
    driver.presentation.value = {
      ...target,
      clip: { ...target.clip, x: target.clip.x + 1 },
    };
    expect(mockNative.setClipPresentation).toHaveBeenCalled();
  });

  it('beginInteraction seeds without echoing back to native', () => {
    const driver = useSmoothClipDriver(initial);
    jest.clearAllMocks();
    mockNative.beginInteraction.mockReturnValueOnce([5, 6, 50, 40, 8, 1, 2]);

    const visible = driver.ui.beginInteraction();

    expect(visible).toEqual({
      clip: { x: 5, y: 6, width: 50, height: 40, radius: 8 },
      contentTranslateX: 1,
      contentTranslateY: 2,
    });
    expect(mockNative.setClipPresentation).not.toHaveBeenCalled();

    driver.presentation.value = target;
    expect(mockNative.setClipPresentation).toHaveBeenCalledTimes(1);
  });

  it('animateTo after a setScalars hot write starts from native state', () => {
    const driver = useSmoothClipDriver(initial);
    driver.ui.setScalars(1, 2, 3, 4, 5, 6, 7);

    driver.ui.animateTo(target, timing);

    // presentation.value is stale after the hot write; native resolves the
    // start from its own latest value instead of snapping back.
    expect(mockNative.animateTiming.mock.calls[0]?.[1]).toBe(false);

    jest.clearAllMocks();
    mockNative.animateTiming.mockReturnValue(7);
    const fresh = useSmoothClipDriver(initial);
    fresh.ui.animateTo(target, timing);
    expect(mockNative.animateTiming.mock.calls[0]?.[1]).toBe(true);
  });

  it('fused from performs the hot write before animating', () => {
    const driver = useSmoothClipDriver(initial);
    jest.clearAllMocks();
    mockNative.animateTiming.mockReturnValue(7);

    const animationId = driver.ui.animateTo(target, {
      ...timing,
      from: fromPresentation,
    });

    expect(animationId).toBe(7);
    expect(mockNative.setClipPresentation).toHaveBeenCalledTimes(1);
    expect(mockNative.setClipPresentation).toHaveBeenCalledWith(
      expect.any(Number),
      2,
      4,
      60,
      50,
      8,
      1,
      3,
      true,
      true,
      true
    );
    const seedOrder =
      mockNative.setClipPresentation.mock.invocationCallOrder[0] ?? 0;
    const animateOrder =
      mockNative.animateTiming.mock.invocationCallOrder[0] ?? 1;
    expect(seedOrder).toBeLessThan(animateOrder);
    // The fused hot write marks scalars stale, so native starts from its
    // own latest value (== from) instead of the stale SharedValue.
    expect(mockNative.animateTiming.mock.calls[0]?.[1]).toBe(false);
    expect(driver.presentation.value).toBe(target);
  });

  it('fused from on keyframes seeds frame zero before the handoff', () => {
    const driver = useSmoothClipDriver(initial);
    jest.clearAllMocks();
    mockNative.animateKeyframes.mockReturnValue(9);

    driver.ui.animateTo(target, {
      type: 'keyframes',
      duration: 300,
      frames: [
        { offset: 0, presentation: fromPresentation },
        { offset: 1, presentation: target },
      ],
      from: fromPresentation,
    });

    expect(mockNative.setClipPresentation).toHaveBeenCalledWith(
      expect.any(Number),
      2,
      4,
      60,
      50,
      8,
      1,
      3,
      true,
      true,
      true
    );
    expect(mockNative.animateKeyframes.mock.calls[0]?.[1]).toBe(false);
  });

  it('animateTo without from performs no hot write', () => {
    const driver = useSmoothClipDriver(initial);
    jest.clearAllMocks();
    mockNative.animateTiming.mockReturnValue(7);

    driver.ui.animateTo(target, timing);

    expect(mockNative.setClipPresentation).not.toHaveBeenCalled();
    expect(mockNative.animateTiming.mock.calls[0]?.[1]).toBe(true);
  });

  it('does not let a later hook seed overwrite an animation-first latch', () => {
    // Model child-before-parent/FIFO scheduling: the effect's seed worklet is
    // queued, while an already-running UI worklet animates this driver first.
    mockUIState().__smoothClipTestQueueUI = true;
    const driver = useSmoothClipDriver(initial);
    const tasks = mockUIState().__smoothClipTestUITasks ?? [];
    expect(tasks).toHaveLength(1);

    const animationId = driver.ui.animateTo(target, timing);
    expect(animationId).toBe(7);
    expect(driver.presentation.value).toBe(target);
    expect(mockNative.setClipPresentation).not.toHaveBeenCalled();

    tasks.shift()?.();
    expect(mockNative.setClipPresentation).not.toHaveBeenCalled();
    expect(driver.presentation.value).toBe(target);
    mockUIState().__smoothClipTestQueueUI = false;
  });

  it('passes the in-frame timestamp at each native trailing position', () => {
    const getAnimationTimestamp = jest.fn(() => 5678);
    (globalThis as { __frameTimestamp?: number }).__frameTimestamp = 1234;
    (
      globalThis as {
        _getAnimationTimestamp?: () => number;
      }
    )._getAnimationTimestamp = getAnimationTimestamp;
    const driver = useSmoothClipDriver(initial);

    driver.ui.animateTo(target, timing);
    driver.ui.animateTo(target, {
      type: 'spring',
      mass: 1,
      stiffness: 180,
      damping: 18,
    });
    driver.ui.animateTo(target, {
      type: 'keyframes',
      duration: 300,
      frames: [
        { offset: 0, presentation: initial },
        { offset: 1, presentation: target },
      ],
    });

    const timingArgs = mockNative.animateTiming.mock.calls[0] ?? [];
    const springArgs = mockNative.animateSpring.mock.calls[0] ?? [];
    const keyframeArgs = mockNative.animateKeyframes.mock.calls[0] ?? [];
    expect(timingArgs).toHaveLength(23);
    expect(springArgs).toHaveLength(23);
    expect(keyframeArgs).toHaveLength(20);
    expect(timingArgs[22]).toBe(1234);
    expect(springArgs[22]).toBe(1234);
    expect(keyframeArgs[19]).toBe(1234);
    expect(getAnimationTimestamp).not.toHaveBeenCalled();
  });

  it('falls back to _getAnimationTimestamp outside the frame callback', () => {
    const getAnimationTimestamp = jest.fn(() => 5678);
    (
      globalThis as {
        _getAnimationTimestamp?: () => number;
      }
    )._getAnimationTimestamp = getAnimationTimestamp;
    const driver = useSmoothClipDriver(initial);

    driver.ui.animateTo(target, timing);

    expect(mockNative.animateTiming.mock.calls[0]?.[22]).toBe(5678);
    expect(getAnimationTimestamp).toHaveBeenCalledTimes(1);
  });

  it('skips the start-stamp capture entirely on iOS', () => {
    // iOS's TurboModule discards the trailing argument positionally (only the
    // Android frame-clock anchor consumes it), so the capture — including the
    // native _getAnimationTimestamp() call — must not happen there at all.
    const getAnimationTimestamp = jest.fn(() => 5678);
    (globalThis as { __frameTimestamp?: number }).__frameTimestamp = 1234;
    (
      globalThis as {
        _getAnimationTimestamp?: () => number;
      }
    )._getAnimationTimestamp = getAnimationTimestamp;
    mockPlatformOS = 'ios';
    let iosUseSmoothClipDriver: typeof useSmoothClipDriver | undefined;
    let iosNative: MockNative | undefined;
    jest.isolateModules(() => {
      iosUseSmoothClipDriver = (
        require('../drivers.native') as typeof import('../drivers.native')
      ).useSmoothClipDriver;
      iosNative = (require('../smoothClipNative') as { default: unknown })
        .default as MockNative;
    });
    const driver = iosUseSmoothClipDriver!(initial);

    driver.ui.animateTo(target, timing);

    expect(iosNative!.animateTiming.mock.calls[0]?.[22]).toBeNaN();
    expect(getAnimationTimestamp).not.toHaveBeenCalled();
  });

  it('rejects every call once the driver is disposed', () => {
    const driver = useSmoothClipDriver(initial);
    const registration = mockEffects[mockEffects.length - 1]!;
    if (typeof registration.cleanup === 'function') registration.cleanup();
    const animateCalls = mockNative.animateTiming.mock.calls.length;
    const setCalls = mockNative.setClipPresentation.mock.calls.length;
    const rejectCalls = mockNative.rejectAnimation.mock.calls.length;
    const cancelCalls = mockNative.cancelAnimation.mock.calls.length;

    // Native cannot tell a post-cleanup call from the pre-registration race —
    // both are a missing registry entry — so an interactive start here would
    // recreate the driver as a latch nothing can start and nothing can cancel,
    // leaking the entry and never delivering the promised completion.
    expect(driver.ui.animateTo(target, timing)).toBe(0);
    const invalidTarget = {
      ...target,
      clip: { ...target.clip, width: Number.NaN },
    };
    expect(driver.ui.animateTo(invalidTarget, timing)).toBe(0);
    expect(
      driver.ui.animateTo(target, { ...timing, duration: Number.NaN })
    ).toBe(0);
    expect(
      driver.ui.animateTo(target, { type: 'spring', mass: Number.NaN })
    ).toBe(0);
    expect(
      driver.ui.animateTo(target, {
        type: 'keyframes',
        duration: Number.NaN,
        frames: [
          { offset: 0, presentation: initial },
          { offset: 1, presentation: target },
        ],
      })
    ).toBe(0);
    expect(
      driver.ui.animateTo(target, {
        ...timing,
        from: {
          ...initial,
          clip: { ...initial.clip, x: Number.NaN },
        },
      })
    ).toBe(0);
    driver.ui.set(target);
    driver.ui.setScalars(1, 2, 3, 4, 5, 6, 7);
    driver.ui.cancel();
    expect(mockNative.animateTiming.mock.calls).toHaveLength(animateCalls);
    expect(mockNative.setClipPresentation.mock.calls).toHaveLength(setCalls);
    // Every entry point, not most of them: cancel is the last path that used
    // to cross into native after the tombstone.
    expect(mockNative.cancelAnimation.mock.calls).toHaveLength(cancelCalls);
    // Not even a rejection id: there is no JS state left to route it to.
    expect(mockNative.rejectAnimation.mock.calls).toHaveLength(rejectCalls);

    // The next effect run owns the driver again and clears the tombstone
    // before the listener or the seed, so nothing after it is rejected.
    registration.effect();
    expect(driver.ui.animateTo(target, timing)).toBe(7);
  });

  it('spends a suppressed-delivery credit even when the seed dedupes', () => {
    const driver = useSmoothClipDriver(initial);

    // Same shape as the replay case below, minus the replay. The cancel seed
    // writes a value deliver() already recorded as `last` (the animateTo
    // delivery was dropped under native ownership without advancing it), so
    // deliver returns on the dedupe branch — before the decrement.
    driver.ui.animateTo(target, timing);
    driver.ui.cancel();
    const setCalls = mockNative.setClipPresentation.mock.calls.length;

    // No cleanup here to launder the credit: an unspent one would swallow this
    // write and leave native one geometry behind for the driver's whole life.
    driver.presentation.value = target;
    expect(mockNative.setClipPresentation.mock.calls).toHaveLength(
      setCalls + 1
    );
  });

  it('rejects out-of-range timing control point x values', () => {
    const driver = useSmoothClipDriver(initial);

    // x outside [0,1] is undefined for a CSS/CA cubic bezier: CoreAnimation
    // clamps while the Android bisection solve returns garbage, so the call
    // must reject instead of diverging silently per platform.
    const animationId = driver.ui.animateTo(target, {
      ...timing,
      controlPoints: [1.5, 0, 0.58, 1] as const,
    });

    expect(animationId).toBe(99);
    expect(mockNative.rejectAnimation).toHaveBeenCalled();
    expect(mockNative.animateTiming).not.toHaveBeenCalled();
  });

  it('resolves fire-and-forget react promises benignly at teardown', async () => {
    mockRNRuntime = true;
    const driver = useSmoothClipDriver(initial);
    const registration = mockEffects[mockEffects.length - 1]!;
    mockUIState().__smoothClipTestQueueUI = true;

    const animatePromise = driver.react.animateTo(target, timing);
    const setPromise = driver.react.set(target);
    const beginPromise = driver.react.beginInteraction();
    if (typeof registration.cleanup === 'function') registration.cleanup();
    mockUIState().__smoothClipTestQueueUI = false;

    // The documented idiom voids animateTo/set; teardown must resolve them
    // with their benign sentinels instead of surfacing an unhandled
    // rejection. Value-carrying calls are always awaited and keep rejecting.
    await expect(animatePromise).resolves.toBe(0);
    await expect(setPromise).resolves.toBeUndefined();
    await expect(beginPromise).rejects.toThrow('Driver was destroyed');
  });

  it('replaying the effect after a torn-down react request still delivers completions', async () => {
    const onAnimationComplete = jest.fn();
    const driver = useSmoothClipDriver(initial, { onAnimationComplete });
    const registration = mockEffects[mockEffects.length - 1]!;

    // A react request is in flight — deferring completion delivery — when
    // cleanup tears the driver down.
    mockUIState().__smoothClipTestQueueUI = true;
    const tornDown = driver.react.animateTo(target, timing);
    if (typeof registration.cleanup === 'function') registration.cleanup();
    // The scheduled worklet lands after teardown; its late resolver runs
    // against a detached state and must not leave the deferral behind.
    const tasks = mockUIState().__smoothClipTestUITasks ?? [];
    while (tasks.length) tasks.shift()?.();
    mockUIState().__smoothClipTestQueueUI = false;
    await expect(tornDown).resolves.toBe(0);

    // StrictMode/<Activity> replay reattaches the SAME driver state. A stale
    // deferral count here would queue every future completion forever.
    registration.effect();
    const completionListener = mockNative.onClipAnimationComplete.mock.calls.at(
      -1
    )?.[0] as (result: {
      driverId: number;
      animationId: number;
      finished: boolean;
    }) => void;
    const driverId = mockNative.setClipPresentation.mock.calls.at(
      -1
    )?.[0] as number;
    expect(driverId).toBeDefined();

    const animationId = driver.ui.animateTo(target, timing);
    completionListener({ driverId, animationId, finished: true });
    expect(onAnimationComplete).toHaveBeenCalledTimes(1);
    expect(onAnimationComplete).toHaveBeenCalledWith({
      animationId,
      finished: true,
    });
  });

  it('rejects a non-finite from without touching native', () => {
    const driver = useSmoothClipDriver(initial);
    jest.clearAllMocks();
    mockNative.rejectAnimation.mockReturnValue(99);

    const animationId = driver.ui.animateTo(target, {
      ...timing,
      from: {
        clip: { x: Number.NaN, y: 0, width: 1, height: 1, radius: 0 },
        contentTranslateX: 0,
        contentTranslateY: 0,
      },
    });

    expect(animationId).toBe(99);
    expect(mockNative.rejectAnimation).toHaveBeenCalled();
    expect(mockNative.setClipPresentation).not.toHaveBeenCalled();
    expect(mockNative.animateTiming).not.toHaveBeenCalled();
  });

  it('fused from rolls back on rejection and re-grabs a running animation', () => {
    const driver = useSmoothClipDriver(initial);

    // (a) Native rejection of a fused call restores the post-hot-write
    // state: presentation untouched, scalars stale again.
    jest.clearAllMocks();
    mockNative.animateTiming.mockReturnValueOnce(0);
    mockNative.rejectAnimation.mockReturnValue(99);
    const rejected = driver.ui.animateTo(target, {
      ...timing,
      from: fromPresentation,
    });
    expect(rejected).toBe(99);
    expect(driver.presentation.value).toBe(initial);
    mockNative.animateTiming.mockReturnValue(7);
    driver.ui.animateTo(target, timing);
    expect(mockNative.animateTiming.mock.calls[1]?.[1]).toBe(false);

    // (b) A fused call interrupting the now-running animation still seeds
    // from — the implicit interactive-start path would have skipped it.
    jest.clearAllMocks();
    mockNative.animateTiming.mockReturnValue(7);
    driver.ui.animateTo(target, { ...timing, from: fromPresentation });
    expect(mockNative.setClipPresentation).toHaveBeenCalledWith(
      expect.any(Number),
      2,
      4,
      60,
      50,
      8,
      1,
      3,
      true,
      true,
      true
    );
    expect(mockNative.animateTiming.mock.calls[0]?.[1]).toBe(false);
  });

  it('flattens keyframes with an eight-scalar stride for native', () => {
    const driver = useSmoothClipDriver(initial);
    driver.ui.animateTo(target, {
      type: 'keyframes',
      duration: 300,
      frames: [
        { offset: 0, presentation: initial },
        { offset: 1, presentation: target },
      ],
    });

    const frames = mockNative.animateKeyframes.mock.calls[0]?.[17] as number[];
    expect(frames).toEqual([
      0,
      initial.clip.x,
      initial.clip.y,
      initial.clip.width,
      initial.clip.height,
      initial.clip.radius,
      initial.contentTranslateX,
      initial.contentTranslateY,
      1,
      target.clip.x,
      target.clip.y,
      target.clip.width,
      target.clip.height,
      target.clip.radius,
      target.contentTranslateX,
      target.contentTranslateY,
    ]);
  });
});
