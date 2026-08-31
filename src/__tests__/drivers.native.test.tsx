import { describe, expect, it, jest } from '@jest/globals';
import {
  canonicalizeClipPresentation,
  type SmoothClipPresentation,
} from '../geometry';
import { PRESENTATION_STRIDE } from '../presentationCodec';

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
    supportsAutonomousComplexPathAnimation: jest.fn(() => false),
    setClipPresentation: jest.fn(),
    setClipPresentationScalars: jest.fn(),
    beginInteraction: jest.fn(() => [0, 0, 100, 80, 12, -4, -8]),
    snapshotCurrent: jest.fn(() => []),
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
  setClipPresentationScalars: jest.Mock;
  beginInteraction: jest.Mock;
  snapshotCurrent: jest.Mock;
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

const canonicalInitial = canonicalizeClipPresentation(initial)!;
const noShadowScalars = [0, 0, 0, 0, 1, 0, 0, 0, 0] as const;

const timing = {
  type: 'timing' as const,
  duration: 250,
  controlPoints: [0.42, 0, 0.58, 1] as const,
};

describe('hybrid native driver animation validation', () => {
  it('rejects unsafe scale springs and accepts a monotonic proof', () => {
    const nativeApi = {
      supportsAutonomousComplexPathAnimation: jest.fn(() => false),
      setClipPresentation: jest.fn(),
      beginInteraction: jest.fn(() => [
        0,
        0,
        100,
        80,
        12,
        12,
        12,
        12,
        0,
        -4,
        -8,
        1,
        ...noShadowScalars,
      ]),
      snapshotCurrent: jest.fn(() => [
        0,
        0,
        100,
        80,
        12,
        12,
        12,
        12,
        0,
        -4,
        -8,
        1,
        ...noShadowScalars,
      ]),
      animateTiming: jest.fn(() => 87),
      animateSpring: jest.fn(() => 88),
      animateKeyframes: jest.fn(() => 89),
      cancelAnimation: jest.fn(() => []),
    };
    Object.assign(mockNative, nativeApi);

    let useDriver: typeof useSmoothClipDriver | undefined;
    jest.isolateModules(() => {
      useDriver = (
        require('../drivers.native') as typeof import('../drivers.native')
      ).useSmoothClipDriver;
    });

    const driver = useDriver!(initial);
    const scaledTarget = { ...target, contentScale: 0.2 };

    expect(
      driver.ui.animateTo(scaledTarget, {
        type: 'spring',
        mass: 1,
        stiffness: 100,
        damping: 10,
        initialVelocity: 0,
      })
    ).toBe(99);
    expect(
      driver.ui.animateTo(scaledTarget, {
        type: 'spring',
        mass: 1,
        stiffness: 100,
        damping: 20,
      })
    ).toBe(99);
    expect(nativeApi.animateSpring).not.toHaveBeenCalled();

    expect(
      driver.ui.animateTo(scaledTarget, {
        type: 'spring',
        mass: 1,
        stiffness: 100,
        damping: 20,
        initialVelocity: 0,
      })
    ).toBe(88);
    expect(nativeApi.snapshotCurrent).toHaveBeenCalled();
    expect(nativeApi.animateSpring).toHaveBeenCalledTimes(1);

    for (const key of Object.keys(nativeApi)) {
      Reflect.deleteProperty(mockNative, key);
    }
  });

  it('validates an implicit retarget curve against native visible state', () => {
    const nativeApi = {
      supportsAutonomousComplexPathAnimation: jest.fn(() => false),
      setClipPresentation: jest.fn(),
      beginInteraction: jest.fn(() => [
        0,
        0,
        100,
        80,
        12,
        12,
        12,
        12,
        1,
        -4,
        -8,
        1,
        ...noShadowScalars,
      ]),
      snapshotCurrent: jest.fn(() => [
        0,
        0,
        100,
        80,
        12,
        12,
        12,
        12,
        1,
        -4,
        -8,
        1,
        ...noShadowScalars,
      ]),
      animateTiming: jest.fn(() => 87),
      animateSpring: jest.fn(() => 88),
      animateKeyframes: jest.fn(() => 89),
      cancelAnimation: jest.fn(() => []),
    };
    Object.assign(mockNative, nativeApi);

    let useDriver: typeof useSmoothClipDriver | undefined;
    jest.isolateModules(() => {
      useDriver = (
        require('../drivers.native') as typeof import('../drivers.native')
      ).useSmoothClipDriver;
    });

    const driver = useDriver!(initial);
    driver.ui.setScalars(0, 0, 100, 80, 12, 12, 12, 12, 1, -4, -8, 1);
    const continuousTarget: SmoothClipPresentation = {
      ...target,
      clip: { ...target.clip, curve: 'continuous' },
    };
    const rejectionCount = mockNative.rejectAnimation.mock.calls.length;

    expect(driver.ui.animateTo(continuousTarget, timing)).toBe(87);
    expect(nativeApi.snapshotCurrent).toHaveBeenCalledTimes(1);
    expect(nativeApi.animateTiming).toHaveBeenCalledTimes(1);
    expect(mockNative.rejectAnimation).toHaveBeenCalledTimes(rejectionCount);

    for (const key of Object.keys(nativeApi)) {
      Reflect.deleteProperty(mockNative, key);
    }
  });

  it('uses one atomic animate call for an explicit start and commits only on success', () => {
    const nativeApi = {
      supportsAutonomousComplexPathAnimation: jest.fn(() => false),
      setClipPresentation: jest.fn(),
      beginInteraction: jest.fn(() => []),
      snapshotCurrent: jest.fn(() => []),
      animateTiming: jest.fn(() => 0),
      animateSpring: jest.fn(() => 88),
      animateKeyframes: jest.fn(() => 89),
      cancelAnimation: jest.fn(() => []),
    };
    Object.assign(mockNative, nativeApi);
    let useDriver: typeof useSmoothClipDriver | undefined;
    jest.isolateModules(() => {
      useDriver = (
        require('../drivers.native') as typeof import('../drivers.native')
      ).useSmoothClipDriver;
    });
    const driver = useDriver!(initial);
    const widenedFrom: SmoothClipPresentation = {
      ...initial,
      clip: {
        ...initial.clip,
        topLeftRadius: 18,
        curve: 'continuous',
      },
      contentScale: 0.9,
    };
    const widenedTarget: SmoothClipPresentation = {
      ...target,
      clip: {
        ...target.clip,
        topLeftRadius: 30,
        curve: 'continuous',
      },
      contentScale: 0.8,
    };
    const seedCalls = nativeApi.setClipPresentation.mock.calls.length;

    expect(
      driver.ui.animateTo(widenedTarget, { ...timing, from: widenedFrom })
    ).toBe(99);
    expect(driver.presentation.value).toEqual(canonicalInitial);
    expect(nativeApi.setClipPresentation).toHaveBeenCalledTimes(seedCalls);
    expect(nativeApi.snapshotCurrent).not.toHaveBeenCalled();
    const timingCalls = nativeApi.animateTiming.mock.calls as unknown[][];
    expect(timingCalls[0]).toHaveLength(10);
    expect(timingCalls[0]?.[1]).toHaveLength(PRESENTATION_STRIDE);
    expect(timingCalls[0]?.[2]).toHaveLength(PRESENTATION_STRIDE);

    nativeApi.animateTiming.mockReturnValueOnce(90);
    expect(
      driver.ui.animateTo(widenedTarget, { ...timing, from: widenedFrom })
    ).toBe(90);
    expect(driver.presentation.value).toEqual(
      canonicalizeClipPresentation(widenedTarget)
    );
    expect(nativeApi.setClipPresentation).toHaveBeenCalledTimes(seedCalls);
    expect(nativeApi.animateTiming).toHaveBeenCalledTimes(2);

    for (const key of Object.keys(nativeApi))
      Reflect.deleteProperty(mockNative, key);
  });

  it('rejects a keyframe start that differs from frame zero atomically', () => {
    const nativeApi = {
      supportsAutonomousComplexPathAnimation: jest.fn(() => false),
      setClipPresentation: jest.fn(),
      beginInteraction: jest.fn(() => []),
      snapshotCurrent: jest.fn(() => []),
      animateTiming: jest.fn(() => 87),
      animateSpring: jest.fn(() => 88),
      animateKeyframes: jest.fn(() => 89),
      cancelAnimation: jest.fn(() => []),
    };
    Object.assign(mockNative, nativeApi);
    let useDriver: typeof useSmoothClipDriver | undefined;
    jest.isolateModules(() => {
      useDriver = (
        require('../drivers.native') as typeof import('../drivers.native')
      ).useSmoothClipDriver;
    });
    const driver = useDriver!(initial);
    const frameZero: SmoothClipPresentation = {
      ...initial,
      clip: { ...initial.clip, curve: 'continuous' },
    };
    const explicitFrom: SmoothClipPresentation = {
      ...frameZero,
      contentTranslateX: 4,
    };
    const widenedTarget: SmoothClipPresentation = {
      ...target,
      clip: { ...target.clip, curve: 'continuous' },
    };
    const seedCalls = nativeApi.setClipPresentation.mock.calls.length;

    expect(
      driver.ui.animateTo(widenedTarget, {
        type: 'keyframes',
        duration: 250,
        from: explicitFrom,
        frames: [
          { offset: 0, presentation: frameZero },
          { offset: 1, presentation: widenedTarget },
        ],
      })
    ).toBe(99);
    expect(driver.presentation.value).toEqual(canonicalInitial);
    expect(nativeApi.animateKeyframes).not.toHaveBeenCalled();
    expect(nativeApi.setClipPresentation).toHaveBeenCalledTimes(seedCalls);

    for (const key of Object.keys(nativeApi))
      Reflect.deleteProperty(mockNative, key);
  });

  it('keeps strict cubic-bezier validation', () => {
    const nativeApi = {
      supportsAutonomousComplexPathAnimation: jest.fn(() => false),
      setClipPresentation: jest.fn(),
      beginInteraction: jest.fn(() => []),
      snapshotCurrent: jest.fn(() => []),
      animateTiming: jest.fn(() => 87),
      animateSpring: jest.fn(() => 88),
      animateKeyframes: jest.fn(() => 89),
      cancelAnimation: jest.fn(() => []),
    };
    Object.assign(mockNative, nativeApi);
    let useDriver: typeof useSmoothClipDriver | undefined;
    jest.isolateModules(() => {
      useDriver = (
        require('../drivers.native') as typeof import('../drivers.native')
      ).useSmoothClipDriver;
    });
    const driver = useDriver!(initial);
    const widenedTarget: SmoothClipPresentation = {
      ...target,
      contentScale: 0.8,
    };

    expect(
      driver.ui.animateTo(widenedTarget, {
        ...timing,
        controlPoints: [1.5, 0, 0.58, 1],
      })
    ).toBe(99);
    expect(nativeApi.snapshotCurrent).not.toHaveBeenCalled();
    expect(nativeApi.animateTiming).not.toHaveBeenCalled();

    for (const key of Object.keys(nativeApi))
      Reflect.deleteProperty(mockNative, key);
  });
});
