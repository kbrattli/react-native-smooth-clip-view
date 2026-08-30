import {
  afterEach,
  beforeEach,
  describe,
  expect,
  it,
  jest,
} from '@jest/globals';

type MockReaction = {
  prepare: () => unknown;
  react: (value: unknown, previous: unknown) => void;
  previous: unknown;
};

type MockAnimation = {
  target: number;
  callback?: (finished?: boolean) => void;
};

type MockSharedValue<T> = {
  _value: T;
  value: T;
  _setRaw(value: T): void;
  addListener(id: number, listener: (value: T) => void): void;
  removeListener(id: number): void;
};

const mockReactions: MockReaction[] = [];
const mockAnimations: Array<{
  shared: MockSharedValue<number>;
  animation: MockAnimation;
}> = [];
const mockEffects: Array<{ cleanup: (() => void) | void }> = [];
let mockRunningReactions = false;

function mockRunReactions(): void {
  if (mockRunningReactions) return;
  mockRunningReactions = true;
  try {
    for (const reaction of mockReactions) {
      const next = reaction.prepare();
      if (!Object.is(next, reaction.previous)) {
        const previous = reaction.previous;
        reaction.previous = next;
        reaction.react(next, previous);
      }
    }
  } finally {
    mockRunningReactions = false;
  }
}

function mockMakeSharedValue<T>(initial: T): MockSharedValue<T> {
  const listeners = new Map<number, (value: T) => void>();
  return {
    _value: initial,
    get value() {
      return this._value;
    },
    set value(next: T) {
      if (typeof next === 'object' && next !== null && 'target' in next) {
        mockAnimations.push({
          shared: this as unknown as MockSharedValue<number>,
          animation: next as unknown as MockAnimation,
        });
        return;
      }
      this._value = next;
      listeners.forEach((listener) => listener(next));
      mockRunReactions();
    },
    _setRaw(next: T) {
      this._value = next;
      listeners.forEach((listener) => listener(next));
      mockRunReactions();
    },
    addListener(id, listener) {
      listeners.set(id, listener);
    },
    removeListener(id) {
      listeners.delete(id);
    },
  };
}

function mockRunCleanups(): void {
  for (let index = mockEffects.length - 1; index >= 0; index -= 1) {
    const effect = mockEffects[index];
    if (typeof effect?.cleanup !== 'function') continue;
    const cleanup = effect.cleanup;
    effect.cleanup = undefined;
    cleanup();
  }
}

jest.mock('react', () => {
  const actual = jest.requireActual<typeof import('react')>('react');
  return {
    ...actual,
    useEffect: (effect: () => (() => void) | void) => {
      mockEffects.push({ cleanup: effect() });
    },
    useRef: (initial: unknown) => ({ current: initial }),
  };
});

jest.mock('react-native-reanimated', () => ({
  cancelAnimation: (shared: MockSharedValue<number>) => {
    for (let index = mockAnimations.length - 1; index >= 0; index -= 1) {
      const running = mockAnimations[index];
      if (running?.shared !== shared) continue;
      mockAnimations.splice(index, 1);
      running.animation.callback?.(false);
    }
  },
  Easing: {
    bezier: (...points: number[]) => points,
    linear: 'linear',
  },
  ReduceMotion: {
    Always: 'always',
    Never: 'never',
    System: 'system',
  },
  useAnimatedReaction: (
    prepare: () => unknown,
    react: (value: unknown, previous: unknown) => void
  ) => {
    mockReactions.push({ prepare, react, previous: prepare() });
  },
  useSharedValue: (initial: unknown) => mockMakeSharedValue(initial),
  withSpring: (
    target: number,
    _configuration: unknown,
    callback?: (finished?: boolean) => void
  ) => ({ target, callback }),
  withTiming: (
    target: number,
    _configuration: unknown,
    callback?: (finished?: boolean) => void
  ) => ({ target, callback }),
}));

jest.mock('react-native-worklets', () => ({
  scheduleOnRN: (fn: (...args: never[]) => void, ...args: never[]) =>
    fn(...args),
  scheduleOnUI: (fn: (...args: never[]) => void, ...args: never[]) =>
    fn(...args),
}));

// The React Native Jest resolver prefers the iOS platform file. This suite
// intentionally exercises the base non-native/web implementation.
jest.mock('../drivers.ios', () => jest.requireActual('../drivers.ts'));

import { useSmoothClipDriver } from '../drivers';
import {
  canonicalizeClipPresentation,
  type CanonicalSmoothClipPresentation,
  type SmoothClipPresentation,
} from '../geometry';

function presentation(x: number): SmoothClipPresentation {
  return {
    clip: {
      x,
      y: x * 2,
      width: 100 + x,
      height: 80 + x,
      radius: 0,
      topLeftRadius: 4 + x,
      topRightRadius: 5 + x,
      bottomRightRadius: 6 + x,
      bottomLeftRadius: 7 + x,
      curve: 'continuous',
    },
    contentTranslateX: x + 8,
    contentTranslateY: x + 9,
    contentScale: 1 + x / 100,
  };
}

function canonical(
  value: SmoothClipPresentation
): CanonicalSmoothClipPresentation {
  const result = canonicalizeClipPresentation(value);
  if (result === null) throw new Error('Expected a canonical presentation.');
  return result;
}

describe('non-native SmoothClip driver', () => {
  beforeEach(() => {
    mockReactions.length = 0;
    mockAnimations.length = 0;
    mockEffects.length = 0;
  });

  afterEach(() => {
    mockRunCleanups();
    mockReactions.length = 0;
    mockAnimations.length = 0;
  });

  it('rejects an explicit keyframe start mismatch before mutating state', () => {
    const initial = presentation(0);
    const explicitFrom = presentation(10);
    const target = presentation(30);
    const driver = useSmoothClipDriver(initial);
    const before = driver.presentation.value;

    driver.ui.animateTo(target, {
      type: 'keyframes',
      duration: 240,
      from: explicitFrom,
      frames: [
        { offset: 0, presentation: presentation(20) },
        { offset: 1, presentation: target },
      ],
    });

    expect(driver.presentation.value).toBe(before);
    expect(driver.__smoothClipHandle?.ownership.value).toBe(0);
    expect(driver.__smoothClipHandle?.activeAnimationId.value).toBe(0);
    expect(mockAnimations).toHaveLength(0);
  });

  it('uses the sampled presentation as implicit keyframe frame zero', () => {
    const initial = presentation(0);
    const target = presentation(40);
    const driver = useSmoothClipDriver(initial);

    driver.ui.animateTo(target, {
      type: 'keyframes',
      duration: 240,
      frames: [
        { offset: 0, presentation: presentation(90) },
        { offset: 1, presentation: target },
      ],
    });

    expect(mockAnimations).toHaveLength(1);
    mockAnimations[0]!.shared._setRaw(0.25);
    expect(driver.presentation.value).toEqual({
      clip: {
        x: 10,
        y: 20,
        width: 110,
        height: 90,
        radius: 0,
        topLeftRadius: 14,
        topRightRadius: 15,
        bottomRightRadius: 16,
        bottomLeftRadius: 17,
        curve: 'continuous',
      },
      contentTranslateX: 18,
      contentTranslateY: 19,
      contentScale: 1.1,
    });
  });

  it('rejects unknown JavaScript animation types without throwing or mutation', () => {
    const driver = useSmoothClipDriver(presentation(0));
    const before = canonical(driver.presentation.value);

    expect(() =>
      driver.ui.animateTo(presentation(20), {
        type: 'Keyframes',
      } as never)
    ).not.toThrow();
    expect(driver.presentation.value).toEqual(before);
    expect(driver.__smoothClipHandle?.activeAnimationId.value).toBe(0);
  });
});
