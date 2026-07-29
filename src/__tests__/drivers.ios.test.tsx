import { beforeEach, describe, expect, it, jest } from '@jest/globals';
import type { SmoothClipPresentation } from '../geometry';

let mockRNRuntime = false;

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
  scheduleOnUI: (fn: (...args: never[]) => void, ...args: never[]) =>
    fn(...args),
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

import { useSmoothClipDriver } from '../drivers.ios';
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

describe('hybrid iOS driver', () => {
  beforeEach(() => {
    mockRNRuntime = false;
    mockEffects.length = 0;
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
      true
    );
    // The SharedValue intentionally stays stale on the hot path.
    expect(driver.presentation.value).toBe(initial);
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
      false
    );
  });

  it('survives an effect replay and revives the destroyed native driver', () => {
    const driver = useSmoothClipDriver(initial);
    const registration = mockEffects[mockEffects.length - 1]!;

    // StrictMode / <Activity>: cleanup runs, then the same effect re-runs.
    if (typeof registration.cleanup === 'function') registration.cleanup();
    expect(mockNative.destroyDriver).toHaveBeenCalled();

    jest.clearAllMocks();
    expect(() => registration.effect()).not.toThrow();

    // The replay re-seeds native with a take-ownership write...
    expect(mockNative.setClipPresentation).toHaveBeenCalledWith(
      expect.any(Number),
      initial.clip.x,
      initial.clip.y,
      initial.clip.width,
      initial.clip.height,
      initial.clip.radius,
      initial.contentTranslateX,
      initial.contentTranslateY,
      true
    );

    // ...and the driver remains fully operational afterwards.
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
      false
    );
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
