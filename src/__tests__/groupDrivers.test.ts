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
  kind: 'spring' | 'timing';
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

type MockEffect = {
  cleanup: (() => void) | void;
};

const mockReactions: MockReaction[] = [];
const mockAnimations: Array<{
  shared: MockSharedValue<number>;
  animation: MockAnimation;
}> = [];
const mockAnimationStarts: MockAnimation[] = [];
const mockEffects: MockEffect[] = [];
let mockRunningReactions = false;
let mockRNRuntime = false;

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
      if (
        typeof next === 'object' &&
        next !== null &&
        'kind' in next &&
        'target' in next
      ) {
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

function mockAdvanceAnimation(progress: number): void {
  const running = mockAnimations[0];
  if (running === undefined) throw new Error('No running mock animation.');
  running.shared._setRaw(progress);
}

function mockAdvanceAnimationAt(index: number, progress: number): void {
  const running = mockAnimations[index];
  if (running === undefined) throw new Error('No running mock animation.');
  running.shared._setRaw(progress);
}

function mockFinishAnimation(finished = true): void {
  const running = mockAnimations.shift();
  if (running === undefined) throw new Error('No running mock animation.');
  if (finished) running.shared._setRaw(running.animation.target);
  running.animation.callback?.(finished);
}

function mockRunCleanups(): void {
  for (let index = mockEffects.length - 1; index >= 0; index -= 1) {
    const effect = mockEffects[index];
    if (typeof effect?.cleanup === 'function') {
      const cleanup = effect.cleanup;
      effect.cleanup = undefined;
      cleanup();
    }
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
  makeMutable: (initial: unknown) => mockMakeSharedValue(initial),
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
  ) => {
    const animation: MockAnimation = { kind: 'spring', target, callback };
    mockAnimationStarts.push(animation);
    return animation;
  },
  withTiming: (
    target: number,
    _configuration: unknown,
    callback?: (finished?: boolean) => void
  ) => {
    const animation: MockAnimation = { kind: 'timing', target, callback };
    mockAnimationStarts.push(animation);
    return animation;
  },
}));

jest.mock('react-native-worklets', () => ({
  isRNRuntime: () => mockRNRuntime,
  scheduleOnRN: (fn: (...args: never[]) => void, ...args: never[]) =>
    fn(...args),
  scheduleOnUI: (fn: (...args: never[]) => void, ...args: never[]) =>
    fn(...args),
}));

// The React Native Jest resolver prefers the iOS platform file. This suite
// intentionally exercises the base non-native/web implementation.
jest.mock('../groupDrivers.ios', () =>
  jest.requireActual('../groupDrivers.ts')
);

import type { SmoothClipDriver } from '../driverTypes';
import {
  canonicalizeClipPresentation,
  type CanonicalSmoothClipPresentation,
  type SmoothClipPresentation,
} from '../geometry';
import { useSmoothClipGroupDriver } from '../groupDrivers';

let nextDriverId = 100;

function canonical(
  input: SmoothClipPresentation
): CanonicalSmoothClipPresentation {
  const result = canonicalizeClipPresentation(input);
  if (result === null) throw new Error('Expected canonical presentation.');
  return result;
}

function presentation(
  x: number,
  radii: readonly [number, number, number, number] = [4, 4, 4, 4],
  curve: 'circular' | 'continuous' = 'circular'
): SmoothClipPresentation {
  return {
    clip: {
      x,
      y: x * 2,
      width: 100 + x,
      height: 80 + x,
      radius: 0,
      topLeftRadius: radii[0],
      topRightRadius: radii[1],
      bottomRightRadius: radii[2],
      bottomLeftRadius: radii[3],
      curve,
    },
    contentTranslateX: x + 5,
    contentTranslateY: x + 6,
    contentScale: 1 + x / 100,
  };
}

function createFakeDriver(initial: SmoothClipPresentation): SmoothClipDriver {
  const initialCanonical = canonical(initial);
  const shared = mockMakeSharedValue<SmoothClipPresentation>(initialCanonical);
  const ownership = mockMakeSharedValue(0);
  const activeAnimationId = mockMakeSharedValue(0);
  const disposed = mockMakeSharedValue(0);
  const ready = mockMakeSharedValue(1);
  nextDriverId += 1;

  const driver = {
    kind: 'hybrid' as const,
    presentation: shared,
    ui: {
      beginInteraction: jest.fn(() => {
        ownership.value = 0;
        activeAnimationId.value = 0;
        return canonical(shared.value);
      }),
      set: jest.fn((next: SmoothClipPresentation) => {
        const result = canonicalizeClipPresentation(next);
        if (result === null) return;
        ownership.value = 0;
        activeAnimationId.value = 0;
        shared.value = result;
      }),
      setScalars: jest.fn(),
      setPresentationScalars: jest.fn(),
      animateTo: jest.fn(() => 0),
      cancel: jest.fn(() => canonical(shared.value)),
    },
    react: {
      beginInteraction: jest.fn(async () => canonical(shared.value)),
      set: jest.fn(async () => undefined),
      animateTo: jest.fn(async () => 0),
      cancel: jest.fn(async () => canonical(shared.value)),
    },
    __smoothClipHandle: {
      driverId: nextDriverId,
      presentation: shared,
      ownership,
      activeAnimationId,
      disposed,
      ready,
    },
  };
  return driver as unknown as SmoothClipDriver;
}

const timing = {
  type: 'timing' as const,
  duration: 250,
  controlPoints: [0.42, 0, 0.58, 1] as const,
};

describe('non-native SmoothClip group driver', () => {
  beforeEach(() => {
    mockReactions.length = 0;
    mockAnimations.length = 0;
    mockAnimationStarts.length = 0;
    mockEffects.length = 0;
    mockRNRuntime = false;
  });

  afterEach(() => {
    mockRunCleanups();
    mockReactions.length = 0;
    mockAnimations.length = 0;
  });

  it('snapshots, begins, and atomically applies validated batches', () => {
    const first = createFakeDriver(presentation(0));
    const second = createFakeDriver(presentation(10));
    const group = useSmoothClipGroupDriver();

    expect(group.ui.snapshotCurrent([first, second])).toEqual([
      { driver: first, presentation: canonical(presentation(0)), ready: true },
      {
        driver: second,
        presentation: canonical(presentation(10)),
        ready: true,
      },
    ]);

    second.__smoothClipHandle!.disposed.value = 1;
    expect(() => group.ui.snapshotCurrent([second])).toThrow(
      'Every group participant must be a live, unique SmoothClip driver.'
    );
    expect(() => group.ui.beginInteraction([second])).toThrow(
      'Every group participant must be a live, unique SmoothClip driver.'
    );
    second.__smoothClipHandle!.disposed.value = 0;

    const beforeFirst = first.presentation.value;
    const beforeSecond = second.presentation.value;
    expect(() =>
      group.ui.setBatch([
        { driver: first, presentation: presentation(20) },
        {
          driver: second,
          presentation: {
            ...presentation(30),
            contentScale: Number.NaN,
          },
        },
      ])
    ).toThrow('Every batch entry must be finite, live, and unique.');
    expect(first.presentation.value).toBe(beforeFirst);
    expect(second.presentation.value).toBe(beforeSecond);

    group.ui.setBatch([
      { driver: first, presentation: presentation(20) },
      { driver: second, presentation: presentation(30) },
    ]);
    expect(first.presentation.value).toEqual(canonical(presentation(20)));
    expect(second.presentation.value).toEqual(canonical(presentation(30)));
  });

  it('uses one timing progress animation for an immutable participant set and all 11 channels', () => {
    const firstStart = presentation(0, [1, 2, 3, 4]);
    const firstTarget = presentation(10, [11, 12, 13, 14]);
    const first = createFakeDriver(firstStart);
    const second = createFakeDriver(presentation(20));
    const late = createFakeDriver(presentation(40));
    const onAnimationComplete = jest.fn();
    const group = useSmoothClipGroupDriver({ onAnimationComplete });
    const entries = [
      { driver: first, target: firstTarget },
      { driver: second, target: presentation(30) },
    ];

    const groupId = group.ui.animateTo(entries, timing);
    entries.push({ driver: late, target: presentation(50) });

    expect(mockAnimationStarts).toHaveLength(1);
    expect(mockAnimationStarts[0]?.kind).toBe('timing');
    mockAdvanceAnimation(0.5);
    expect(first.presentation.value).toEqual({
      clip: {
        x: 5,
        y: 10,
        width: 105,
        height: 85,
        radius: 0,
        topLeftRadius: 6,
        topRightRadius: 7,
        bottomRightRadius: 8,
        bottomLeftRadius: 9,
        curve: 'circular',
      },
      contentTranslateX: 10,
      contentTranslateY: 11,
      contentScale: 1.05,
    });
    expect(second.presentation.value).toEqual(canonical(presentation(25)));
    expect(late.presentation.value).toEqual(canonical(presentation(40)));

    mockFinishAnimation();
    expect(first.presentation.value).toEqual(canonical(firstTarget));
    expect(onAnimationComplete).toHaveBeenCalledTimes(1);
    expect(onAnimationComplete).toHaveBeenCalledWith({
      groupId,
      finished: true,
    });
    expect(group.ui.cancel(groupId)).toEqual([]);
    expect(onAnimationComplete).toHaveBeenCalledTimes(1);
  });

  it('keeps disjoint groups active concurrently with process-global IDs', () => {
    const first = createFakeDriver(presentation(0));
    const second = createFakeDriver(presentation(20));
    const onAnimationComplete = jest.fn();
    const group = useSmoothClipGroupDriver({ onAnimationComplete });

    const firstGroupId = group.ui.animateTo(
      [{ driver: first, target: presentation(10) }],
      timing
    );
    const secondGroupId = group.ui.animateTo(
      [{ driver: second, target: presentation(40) }],
      timing
    );

    expect(secondGroupId).not.toBe(firstGroupId);
    expect(mockAnimations).toHaveLength(2);
    mockAdvanceAnimationAt(0, 0.5);
    mockAdvanceAnimationAt(1, 0.25);
    expect(first.presentation.value).toEqual(canonical(presentation(5)));
    expect(second.presentation.value).toEqual(canonical(presentation(25)));
    expect(first.__smoothClipHandle?.activeAnimationId.value).toBe(
      firstGroupId
    );
    expect(second.__smoothClipHandle?.activeAnimationId.value).toBe(
      secondGroupId
    );

    mockFinishAnimation();
    mockFinishAnimation();
    expect(onAnimationComplete).toHaveBeenCalledWith({
      groupId: firstGroupId,
      finished: true,
    });
    expect(onAnimationComplete).toHaveBeenCalledWith({
      groupId: secondGroupId,
      finished: true,
    });
  });

  it('atomically replaces only intersecting groups across controllers', () => {
    const first = createFakeDriver(presentation(0));
    const shared = createFakeDriver(presentation(10));
    const third = createFakeDriver(presentation(30));
    const firstCompletion = jest.fn();
    const secondCompletion = jest.fn();
    const firstController = useSmoothClipGroupDriver({
      onAnimationComplete: firstCompletion,
    });
    const secondController = useSmoothClipGroupDriver({
      onAnimationComplete: secondCompletion,
    });
    const replacedId = firstController.ui.animateTo(
      [
        { driver: first, target: presentation(20) },
        { driver: shared, target: presentation(30) },
      ],
      timing
    );

    const replacementId = secondController.ui.animateTo(
      [
        { driver: shared, target: presentation(40) },
        { driver: third, target: presentation(50) },
      ],
      timing
    );

    expect(replacementId).not.toBe(replacedId);
    expect(mockAnimations).toHaveLength(1);
    expect(first.__smoothClipHandle?.activeAnimationId.value).toBe(0);
    expect(shared.__smoothClipHandle?.activeAnimationId.value).toBe(
      replacementId
    );
    expect(third.__smoothClipHandle?.activeAnimationId.value).toBe(
      replacementId
    );
    expect(firstCompletion).toHaveBeenCalledWith({
      groupId: replacedId,
      finished: false,
    });
    expect(secondCompletion).not.toHaveBeenCalled();
  });

  it('rejects the whole animation for invalid values or a curve change', () => {
    const first = createFakeDriver(presentation(0));
    const second = createFakeDriver(presentation(10));
    const onAnimationComplete = jest.fn();
    const group = useSmoothClipGroupDriver({ onAnimationComplete });
    const firstBefore = first.presentation.value;
    const secondBefore = second.presentation.value;

    expect(() =>
      group.ui.animateTo(
        [
          { driver: first, target: presentation(20) },
          {
            driver: second,
            target: { ...presentation(30), contentScale: 0 },
          },
        ],
        timing
      )
    ).toThrow('Group animation entries or configuration are invalid.');
    expect(() =>
      group.ui.animateTo(
        [
          {
            driver: first,
            target: presentation(20, [4, 4, 4, 4], 'continuous'),
          },
        ],
        timing
      )
    ).toThrow('Group animation entries or configuration are invalid.');

    expect(mockAnimationStarts).toHaveLength(0);
    expect(first.presentation.value).toBe(firstBefore);
    expect(second.presentation.value).toBe(secondBefore);
    expect(onAnimationComplete).not.toHaveBeenCalled();
  });

  it('linearly interpolates each participant keyframe track on shared progress', () => {
    const start = presentation(0, [1, 2, 3, 4]);
    const middle = presentation(40, [5, 6, 7, 8]);
    const target = presentation(100, [9, 10, 11, 12]);
    const driver = createFakeDriver(start);
    const group = useSmoothClipGroupDriver();

    group.ui.animateTo(
      [
        {
          driver,
          from: start,
          target,
          frames: [
            { offset: 0, presentation: start },
            { offset: 0.25, presentation: middle },
            { offset: 1, presentation: target },
          ],
        },
      ],
      { type: 'keyframes', duration: 300 }
    );

    expect(mockAnimationStarts).toHaveLength(1);
    expect(mockAnimationStarts[0]?.kind).toBe('timing');
    mockAdvanceAnimation(0.625);
    expect(driver.presentation.value).toEqual({
      clip: {
        x: 70,
        y: 140,
        width: 170,
        height: 150,
        radius: 0,
        topLeftRadius: 7,
        topRightRadius: 8,
        bottomRightRadius: 9,
        bottomLeftRadius: 10,
        curve: 'circular',
      },
      contentTranslateX: 75,
      contentTranslateY: 76,
      contentScale: 1.7,
    });
  });

  it('substitutes the sampled start for an implicit keyframe frame zero', () => {
    const start = presentation(10);
    const target = presentation(30);
    const driver = createFakeDriver(start);
    const group = useSmoothClipGroupDriver();

    group.ui.animateTo(
      [
        {
          driver,
          target,
          frames: [
            { offset: 0, presentation: presentation(90) },
            { offset: 1, presentation: target },
          ],
        },
      ],
      { type: 'keyframes', duration: 300 }
    );

    mockAdvanceAnimation(0.5);
    expect(driver.presentation.value).toEqual({
      ...canonical(presentation(20)),
      contentScale: expect.closeTo(1.2),
    });
  });

  it('uses one spring progress animation', () => {
    const first = createFakeDriver(presentation(0));
    const second = createFakeDriver(presentation(10));
    const group = useSmoothClipGroupDriver();

    expect(() =>
      group.ui.animateTo(
        [
          { driver: first, target: presentation(20) },
          { driver: second, target: presentation(30) },
        ],
        { type: 'spring' }
      )
    ).toThrow(
      'This scale-changing spring is not provably positive; compile it to keyframes.'
    );
    expect(mockAnimationStarts).toHaveLength(0);

    group.ui.animateTo(
      [
        { driver: first, target: presentation(20) },
        { driver: second, target: presentation(30) },
      ],
      { type: 'spring', initialVelocity: 0, damping: 20 }
    );

    expect(mockAnimationStarts).toHaveLength(1);
    expect(mockAnimationStarts[0]?.kind).toBe('spring');
    mockAdvanceAnimation(0.5);
    expect(first.presentation.value).toEqual(canonical(presentation(10)));
    expect(second.presentation.value).toEqual({
      ...canonical(presentation(20)),
      contentScale: expect.closeTo(1.2),
    });
  });

  it('freezes or finishes every owned participant and completes once', () => {
    const first = createFakeDriver(presentation(0));
    const second = createFakeDriver(presentation(10));
    const onAnimationComplete = jest.fn();
    const group = useSmoothClipGroupDriver({ onAnimationComplete });

    const frozenId = group.ui.animateTo(
      [
        { driver: first, target: presentation(20) },
        { driver: second, target: presentation(30) },
      ],
      timing
    );
    mockAdvanceAnimation(0.5);
    const frozenFirst = first.presentation.value;
    const frozen = group.ui.cancel(frozenId, 'freeze');
    expect(frozen[0]?.presentation).toEqual(frozenFirst);
    expect(first.presentation.value).toBe(frozenFirst);
    expect(onAnimationComplete).toHaveBeenLastCalledWith({
      groupId: frozenId,
      finished: false,
    });

    const finishedTarget = presentation(50);
    const finishedId = group.ui.animateTo(
      [{ driver: first, target: finishedTarget }],
      timing
    );
    mockAdvanceAnimation(0.25);
    const finished = group.ui.cancel(finishedId, 'finish');
    expect(finished[0]?.presentation).toEqual(canonical(finishedTarget));
    expect(first.presentation.value).toEqual(canonical(finishedTarget));
    expect(onAnimationComplete).toHaveBeenLastCalledWith({
      groupId: finishedId,
      finished: true,
    });
    expect(onAnimationComplete).toHaveBeenCalledTimes(2);
  });

  it('invalidates the complete immutable group if one participant is interrupted', () => {
    const first = createFakeDriver(presentation(0));
    const second = createFakeDriver(presentation(10));
    const onAnimationComplete = jest.fn();
    const group = useSmoothClipGroupDriver({ onAnimationComplete });
    const groupId = group.ui.animateTo(
      [
        { driver: first, target: presentation(20) },
        { driver: second, target: presentation(30) },
      ],
      timing
    );

    first.__smoothClipHandle!.ownership.value = 1;
    first.__smoothClipHandle!.activeAnimationId.value = 999;

    expect(first.__smoothClipHandle!.activeAnimationId.value).toBe(999);
    expect(second.__smoothClipHandle!.activeAnimationId.value).toBe(0);
    expect(onAnimationComplete).toHaveBeenCalledWith({
      groupId,
      finished: false,
    });
    expect(onAnimationComplete).toHaveBeenCalledTimes(1);
  });

  it('cannot confuse an equal individual animation ID with group ownership', () => {
    const driver = createFakeDriver(presentation(0));
    const onAnimationComplete = jest.fn();
    const group = useSmoothClipGroupDriver({ onAnimationComplete });
    const groupId = group.ui.animateTo(
      [{ driver, target: presentation(20) }],
      timing
    );

    // Fallback individual IDs are per driver and may equal a global group ID.
    driver.__smoothClipHandle!.activeAnimationId.value = groupId;
    driver.__smoothClipHandle!.ownership.value = 1;

    expect(mockAnimations).toHaveLength(0);
    expect(driver.__smoothClipHandle?.activeAnimationId.value).toBe(groupId);
    expect(driver.__smoothClipHandle?.ownership.value).toBe(1);
    expect(onAnimationComplete).toHaveBeenCalledWith({
      groupId,
      finished: false,
    });
  });

  it('pauses until every host is ready and resumes the whole group', () => {
    const first = createFakeDriver(presentation(0));
    const second = createFakeDriver(presentation(10));
    const group = useSmoothClipGroupDriver();
    const secondReady = second.__smoothClipHandle?.ready;
    if (secondReady === undefined) throw new Error('Expected readiness state.');
    secondReady.value = 0;

    const groupId = group.ui.animateTo(
      [
        { driver: first, target: presentation(20) },
        { driver: second, target: presentation(30) },
      ],
      timing
    );
    expect(mockAnimations).toHaveLength(0);
    expect(first.__smoothClipHandle?.activeAnimationId.value).toBe(groupId);

    secondReady.value = 1;
    expect(mockAnimations).toHaveLength(1);
    mockAdvanceAnimation(0.4);
    const frozen = first.presentation.value;
    secondReady.value = 0;
    expect(mockAnimations).toHaveLength(0);
    expect(first.presentation.value).toBe(frozen);

    secondReady.value = 1;
    expect(mockAnimations).toHaveLength(1);
    mockFinishAnimation();
    expect(first.presentation.value).toEqual(canonical(presentation(20)));
    expect(second.presentation.value).toEqual(canonical(presentation(30)));
  });

  it('finishes every target if a finish-policy participant loses readiness', () => {
    const first = createFakeDriver(presentation(0));
    const second = createFakeDriver(presentation(10));
    const onAnimationComplete = jest.fn();
    const group = useSmoothClipGroupDriver({ onAnimationComplete });
    const groupId = group.ui.animateTo(
      [
        { driver: first, target: presentation(20) },
        { driver: second, target: presentation(30) },
      ],
      { ...timing, suspensionPolicy: 'finish' }
    );
    const secondReady = second.__smoothClipHandle?.ready;
    if (secondReady === undefined) throw new Error('Expected readiness state.');

    secondReady.value = 0;

    expect(mockAnimations).toHaveLength(0);
    expect(first.presentation.value).toEqual(canonical(presentation(20)));
    expect(second.presentation.value).toEqual(canonical(presentation(30)));
    expect(onAnimationComplete).toHaveBeenCalledWith({
      groupId,
      finished: true,
    });
  });

  it('latches an initially unready finish-policy group until all hosts are ready', () => {
    const first = createFakeDriver(presentation(0));
    const second = createFakeDriver(presentation(10));
    const onAnimationComplete = jest.fn();
    const group = useSmoothClipGroupDriver({ onAnimationComplete });
    const secondReady = second.__smoothClipHandle?.ready;
    if (secondReady === undefined) throw new Error('Expected readiness state.');
    secondReady.value = 0;

    const groupId = group.ui.animateTo(
      [
        { driver: first, target: presentation(20) },
        { driver: second, target: presentation(30) },
      ],
      { ...timing, suspensionPolicy: 'finish' }
    );

    expect(groupId).toBeGreaterThan(0);
    expect(mockAnimations).toHaveLength(0);
    expect(first.presentation.value).toEqual(canonical(presentation(0)));
    expect(second.presentation.value).toEqual(canonical(presentation(10)));
    expect(onAnimationComplete).not.toHaveBeenCalled();

    secondReady.value = 1;
    expect(mockAnimations).toHaveLength(1);
    mockAdvanceAnimation(0.25);
    secondReady.value = 0;
    expect(first.presentation.value).toEqual(canonical(presentation(20)));
    expect(second.presentation.value).toEqual(canonical(presentation(30)));
    expect(onAnimationComplete).toHaveBeenCalledWith({
      groupId,
      finished: true,
    });
  });

  it('rejects ui controls on the React runtime while React controls dispatch', async () => {
    const driver = createFakeDriver(presentation(0));
    const group = useSmoothClipGroupDriver();
    mockRNRuntime = true;

    expect(() => group.ui.snapshotCurrent([driver])).toThrow(
      'group.ui methods must run on the UI runtime'
    );
    await expect(group.react.snapshotCurrent([driver])).resolves.toHaveLength(
      1
    );
  });

  it('delivers React-triggered completion after its Promise reaction', async () => {
    const driver = createFakeDriver(presentation(0));
    const order: string[] = [];
    const group = useSmoothClipGroupDriver({
      onAnimationComplete: () => order.push('callback'),
    });
    const groupId = await group.react.animateTo(
      [{ driver, target: presentation(20) }],
      timing
    );
    await Promise.resolve();

    await group.react.cancel(groupId).then(() => order.push('promise'));

    expect(order).toEqual(['promise', 'callback']);
  });

  it('provides Promise React wrappers and releases ownership during cleanup', async () => {
    const driver = createFakeDriver(presentation(0));
    const onAnimationComplete = jest.fn();
    const group = useSmoothClipGroupDriver({ onAnimationComplete });

    await expect(group.react.snapshotCurrent([driver])).resolves.toEqual([
      { driver, presentation: canonical(presentation(0)), ready: true },
    ]);
    await group.react.setBatch([{ driver, presentation: presentation(10) }]);
    expect(driver.presentation.value).toEqual(canonical(presentation(10)));
    await expect(
      group.react.animateTo(
        [
          {
            driver,
            target: { ...presentation(20), contentScale: 0 },
          },
        ],
        timing
      )
    ).rejects.toThrow('Group animation entries or configuration are invalid.');
    expect(onAnimationComplete).not.toHaveBeenCalled();
    const groupId = await group.react.animateTo(
      [{ driver, target: presentation(20) }],
      timing
    );
    expect(driver.__smoothClipHandle!.activeAnimationId.value).toBe(groupId);

    mockRunCleanups();
    expect(driver.__smoothClipHandle!.activeAnimationId.value).toBe(0);
    expect(driver.__smoothClipHandle!.ownership.value).toBe(0);
    await Promise.resolve();
    await Promise.resolve();
    expect(onAnimationComplete).toHaveBeenCalledWith({
      groupId,
      finished: false,
    });
    expect(() => group.ui.snapshotCurrent([driver])).toThrow(
      'Group driver was destroyed.'
    );
    expect(() =>
      group.ui.setBatch([{ driver, presentation: presentation(30) }])
    ).not.toThrow();
    await expect(
      group.react.setBatch([{ driver, presentation: presentation(30) }])
    ).rejects.toThrow('Group driver was destroyed.');
  });
});
