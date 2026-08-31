import {
  afterEach,
  beforeEach,
  describe,
  expect,
  it,
  jest,
} from '@jest/globals';
import type {
  InternalSmoothClipDriver,
  SmoothClipDriver,
} from '../driverTypes';
import {
  canonicalizeClipPresentation,
  type SmoothClipPresentation,
} from '../geometry';
import { PRESENTATION_STRIDE, presentationPacket } from '../presentationCodec';

function mockMakeSharedValue<T>(initial: T) {
  return { value: initial };
}

type MockEffect = { cleanup: (() => void) | void };
const mockEffects: MockEffect[] = [];

function mockRunCleanups(): void {
  for (let index = mockEffects.length - 1; index >= 0; index -= 1) {
    const effect = mockEffects[index];
    if (typeof effect?.cleanup !== 'function') continue;
    const cleanup = effect.cleanup;
    effect.cleanup = undefined;
    cleanup();
  }
}

jest.mock('react', () => ({
  useEffect: (effect: () => (() => void) | void) => {
    mockEffects.push({ cleanup: effect() });
  },
  useRef: (initial: unknown) => ({ current: initial }),
}));

jest.mock('react-native', () => ({ Platform: { OS: 'ios' } }));

jest.mock('react-native-reanimated', () => ({
  useSharedValue: (initial: unknown) => mockMakeSharedValue(initial),
}));

jest.mock('react-native-worklets', () => ({
  isRNRuntime: () => false,
  scheduleOnUI: (fn: (...args: never[]) => void, ...args: never[]) =>
    fn(...args),
  scheduleOnRN: (fn: (...args: never[]) => void, ...args: never[]) =>
    fn(...args),
}));

let completionListener:
  | ((result: {
      controllerId: number;
      groupId: number;
      finished: boolean;
      driverIds: readonly number[];
    }) => void)
  | undefined;

jest.mock('../smoothClipNative', () => ({
  __esModule: true,
  default: {
    beginGroupInteraction: jest.fn(),
    snapshotGroup: jest.fn(),
    setClipPresentationBatch: jest.fn(() => true),
    animateTimingGroup: jest.fn(() => 21),
    animateSpringGroup: jest.fn(() => 22),
    animateKeyframesGroup: jest.fn(() => 23),
    cancelAnimationGroup: jest.fn(),
    onClipGroupAnimationComplete: jest.fn(
      (listener: typeof completionListener) => {
        completionListener = listener;
        return { remove: jest.fn() };
      }
    ),
  },
}));

import { useSmoothClipGroupDriver } from '../groupDrivers.native';
import nativeModule from '../smoothClipNative';

const native = nativeModule as unknown as {
  beginGroupInteraction: jest.Mock;
  snapshotGroup: jest.Mock;
  setClipPresentationBatch: jest.Mock;
  animateTimingGroup: jest.Mock;
  animateSpringGroup: jest.Mock;
  animateKeyframesGroup: jest.Mock;
  cancelAnimationGroup: jest.Mock;
};

const firstPresentation: SmoothClipPresentation = {
  clip: {
    x: 1,
    y: 2,
    width: 100,
    height: 80,
    radius: 0,
    topLeftRadius: 4,
    topRightRadius: 8,
    bottomRightRadius: 12,
    bottomLeftRadius: 16,
    curve: 'continuous',
  },
  contentTranslateX: -3,
  contentTranslateY: -5,
  contentScale: 1.25,
};

const secondPresentation: SmoothClipPresentation = {
  clip: { x: 5, y: 6, width: 40, height: 30, radius: 7 },
  contentTranslateX: 2,
  contentTranslateY: 3,
  contentScale: 1,
};

const firstCircularPresentation: SmoothClipPresentation = {
  ...firstPresentation,
  clip: { ...firstPresentation.clip, curve: 'circular' },
};

function presentationValues(presentation: SmoothClipPresentation): number[] {
  const canonical = canonicalizeClipPresentation(presentation);
  if (canonical === null) throw new Error('invalid test presentation');
  return presentationPacket(canonical);
}

function snapshots(
  ...entries: Array<[boolean, SmoothClipPresentation]>
): number[] {
  return entries.flatMap(([ready, presentation]) => [
    ready ? 1 : 0,
    ...presentationValues(presentation),
  ]);
}

function unavailableSnapshots(count: number): number[] {
  return Array.from({ length: count }, () => [
    0,
    ...Array.from({ length: PRESENTATION_STRIDE }, () => Number.NaN),
  ]).flat();
}

let nextDriverId = 100;

function createDriver(
  presentation: SmoothClipPresentation = secondPresentation
): InternalSmoothClipDriver {
  nextDriverId += 1;
  const source = mockMakeSharedValue(presentation);
  return {
    kind: 'hybrid',
    presentation: source,
    ui: {} as SmoothClipDriver['ui'],
    react: {} as SmoothClipDriver['react'],
    __smoothClipHandle: {
      driverId: nextDriverId,
      presentation: source,
      ownership: mockMakeSharedValue(0),
      activeAnimationId: mockMakeSharedValue(0),
      disposed: mockMakeSharedValue(0),
    },
  } as unknown as InternalSmoothClipDriver;
}

describe('native SmoothClip group driver', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    completionListener = undefined;
    mockEffects.length = 0;
    native.setClipPresentationBatch.mockReturnValue(true);
    native.animateTimingGroup.mockReturnValue(21);
    native.animateSpringGroup.mockReturnValue(22);
    native.animateKeyframesGroup.mockReturnValue(23);
    native.cancelAnimationGroup.mockReturnValue([]);
  });

  afterEach(() => {
    mockRunCleanups();
  });

  it('encodes and commits a complete batch in one native call', () => {
    const first = createDriver();
    const second = createDriver();
    const group = useSmoothClipGroupDriver();

    group.ui.setBatch([
      { driver: first, presentation: firstPresentation },
      { driver: second, presentation: secondPresentation },
    ]);

    expect(native.setClipPresentationBatch).toHaveBeenCalledWith([
      first.__smoothClipHandle?.driverId,
      ...presentationValues(firstPresentation),
      second.__smoothClipHandle?.driverId,
      ...presentationValues(secondPresentation),
    ]);
    expect(first.presentation.value).toMatchObject({ contentScale: 1.25 });
    expect(first.__smoothClipHandle?.ownership.value).toBe(0);
  });

  it('rejects duplicate drivers before mutating native', () => {
    const driver = createDriver();
    const group = useSmoothClipGroupDriver();

    expect(() =>
      group.ui.setBatch([
        { driver, presentation: firstPresentation },
        { driver, presentation: secondPresentation },
      ])
    ).toThrow('duplicate drivers');
    expect(native.setClipPresentationBatch).not.toHaveBeenCalled();
  });

  it('returns snapshot readiness and driver identity in input order', () => {
    const first = createDriver();
    const second = createDriver();
    native.snapshotGroup.mockReturnValue(
      snapshots([true, firstCircularPresentation], [false, secondPresentation])
    );
    const group = useSmoothClipGroupDriver();

    const result = group.ui.snapshotCurrent([first, second]);

    expect(result.map(({ driver, ready }) => [driver, ready])).toEqual([
      [first, true],
      [second, false],
    ]);
  });

  it('uses the handle presentation when native reports an unavailable host', () => {
    const driver = createDriver(secondPresentation);
    native.snapshotGroup.mockReturnValue(unavailableSnapshots(1));
    native.beginGroupInteraction.mockReturnValue(unavailableSnapshots(1));
    const group = useSmoothClipGroupDriver();

    expect(group.ui.snapshotCurrent([driver])).toEqual([
      {
        driver,
        presentation: canonicalizeClipPresentation(secondPresentation),
        ready: false,
      },
    ]);

    driver.__smoothClipHandle!.ownership.value = 1;
    driver.__smoothClipHandle!.activeAnimationId.value = 91;
    expect(group.ui.beginInteraction([driver])).toEqual([
      {
        driver,
        presentation: canonicalizeClipPresentation(secondPresentation),
        ready: false,
      },
    ]);
    expect(driver.__smoothClipHandle?.activeAnimationId.value).toBe(91);
    expect(driver.__smoothClipHandle?.ownership.value).toBe(1);
  });

  it('encodes one timing group and clears only its matching ownership', () => {
    const first = createDriver();
    const second = createDriver();
    native.snapshotGroup.mockReturnValue(
      snapshots([true, secondPresentation], [true, secondPresentation])
    );
    const onAnimationComplete = jest.fn();
    const group = useSmoothClipGroupDriver({ onAnimationComplete });

    const groupId = group.ui.animateTo(
      [
        { driver: first, target: firstCircularPresentation },
        { driver: second, target: secondPresentation },
      ],
      {
        type: 'timing',
        duration: 240,
        controlPoints: [0.42, 0, 0.58, 1],
      }
    );

    expect(groupId).toBe(21);
    expect(native.animateTimingGroup.mock.calls[0]?.[1]).toHaveLength(88);
    expect(first.__smoothClipHandle?.activeAnimationId.value).toBe(21);
    const controllerId = native.animateTimingGroup.mock.calls[0]?.[0] as number;
    completionListener?.({
      controllerId,
      groupId: 21,
      finished: true,
      driverIds: [
        first.__smoothClipHandle?.driverId as number,
        second.__smoothClipHandle?.driverId as number,
      ],
    });
    expect(first.__smoothClipHandle?.activeAnimationId.value).toBe(0);
    expect(onAnimationComplete).toHaveBeenCalledWith({
      groupId: 21,
      finished: true,
    });
  });

  it('uses the shared keyframe packet stride and rejects inconsistent frame zero', () => {
    const driver = createDriver();
    const group = useSmoothClipGroupDriver();

    const groupId = group.ui.animateTo(
      [
        {
          driver,
          from: secondPresentation,
          target: firstCircularPresentation,
          frames: [
            { offset: 0, presentation: secondPresentation },
            { offset: 1, presentation: firstCircularPresentation },
          ],
        },
      ],
      { type: 'keyframes', duration: 180 }
    );

    expect(groupId).toBe(23);
    expect(native.animateKeyframesGroup.mock.calls[0]?.[1]).toHaveLength(89);
    expect(() =>
      group.ui.animateTo(
        [
          {
            driver,
            from: firstCircularPresentation,
            target: firstCircularPresentation,
            frames: [
              { offset: 0, presentation: secondPresentation },
              { offset: 1, presentation: firstCircularPresentation },
            ],
          },
        ],
        { type: 'keyframes', duration: 180 }
      )
    ).toThrow('keyframes are inconsistent');
  });

  it('substitutes the sampled start into implicit keyframe frame zero', () => {
    const driver = createDriver(secondPresentation);
    native.snapshotGroup.mockReturnValue(snapshots([true, secondPresentation]));
    const group = useSmoothClipGroupDriver();

    group.ui.animateTo(
      [
        {
          driver,
          target: firstCircularPresentation,
          frames: [
            { offset: 0, presentation: firstCircularPresentation },
            { offset: 1, presentation: firstCircularPresentation },
          ],
        },
      ],
      { type: 'keyframes', duration: 180 }
    );

    const values = native.animateKeyframesGroup.mock.calls[0]?.[1] as number[];
    expect(values[1]).toBe(0);
    expect(values.slice(46, 67)).toEqual(
      presentationValues(secondPresentation)
    );
  });

  it('rejects curve changes and unproven scale springs before dispatch', () => {
    const driver = createDriver(secondPresentation);
    native.snapshotGroup.mockReturnValue(snapshots([true, secondPresentation]));
    const group = useSmoothClipGroupDriver();

    expect(() =>
      group.ui.animateTo([{ driver, target: firstPresentation }], {
        type: 'timing',
        duration: 100,
        controlPoints: [0, 0, 1, 1],
      })
    ).toThrow('Curve-changing');

    const scaleTarget: SmoothClipPresentation = {
      ...secondPresentation,
      contentScale: 0.25,
    };
    expect(() =>
      group.ui.animateTo(
        [{ driver, from: secondPresentation, target: scaleTarget }],
        { type: 'spring', damping: 10, mass: 1, stiffness: 100 }
      )
    ).toThrow('not provably positive');
    expect(native.animateSpringGroup).not.toHaveBeenCalled();
  });

  it('strictly rejects malformed animations and cancel behavior', () => {
    const driver = createDriver(secondPresentation);
    const group = useSmoothClipGroupDriver();

    expect(() =>
      group.ui.animateTo(
        [{ driver, from: secondPresentation, target: secondPresentation }],
        {
          type: 'timing',
          duration: 100,
          controlPoints: [0, 0, 1],
        } as never
      )
    ).toThrow('Group animation is invalid.');
    expect(() =>
      group.ui.animateTo(
        [{ driver, from: secondPresentation, target: secondPresentation }],
        {
          ...({
            type: 'keyframes',
            duration: 100,
          } as const),
          suspensionPolicy: 'resume',
        } as never
      )
    ).toThrow('Group animation is invalid.');
    expect(() => group.ui.cancel(1, 'current' as never)).toThrow(
      'cancel behavior is invalid'
    );
    expect(native.animateTimingGroup).not.toHaveBeenCalled();
    expect(native.animateKeyframesGroup).not.toHaveBeenCalled();
    expect(native.cancelAnimationGroup).not.toHaveBeenCalled();
  });

  it('returns all participant snapshots on cancellation', () => {
    const first = createDriver();
    const second = createDriver();
    native.snapshotGroup.mockReturnValue(
      snapshots([true, secondPresentation], [true, secondPresentation])
    );
    native.cancelAnimationGroup.mockReturnValue(
      snapshots([true, firstCircularPresentation], [false, secondPresentation])
    );
    const group = useSmoothClipGroupDriver();
    const groupId = group.ui.animateTo(
      [
        { driver: first, target: firstCircularPresentation },
        { driver: second, target: secondPresentation },
      ],
      {
        type: 'timing',
        duration: 100,
        controlPoints: [0, 0, 1, 1],
      }
    );

    const result = group.ui.cancel(groupId, 'freeze');

    expect(native.cancelAnimationGroup).toHaveBeenCalledWith(groupId, 0);
    expect(result).toHaveLength(2);
    expect(result[0]?.driver).toBe(first);
    expect(result[1]?.ready).toBe(false);
  });

  it('returns an empty stale cancel and clears matching JS ownership', () => {
    const driver = createDriver();
    const group = useSmoothClipGroupDriver();
    const groupId = group.ui.animateTo(
      [
        {
          driver,
          from: secondPresentation,
          target: secondPresentation,
        },
      ],
      {
        type: 'timing',
        duration: 100,
        controlPoints: [0, 0, 1, 1],
      }
    );
    native.cancelAnimationGroup.mockReturnValue([]);

    expect(group.ui.cancel(groupId)).toEqual([]);
    expect(driver.__smoothClipHandle?.activeAnimationId.value).toBe(0);
    expect(driver.__smoothClipHandle?.ownership.value).toBe(0);
  });

  it('does not let another controller cancel a group it does not own', () => {
    const driver = createDriver();
    const owner = useSmoothClipGroupDriver();
    const stranger = useSmoothClipGroupDriver();
    const groupId = owner.ui.animateTo(
      [
        {
          driver,
          from: secondPresentation,
          target: secondPresentation,
        },
      ],
      {
        type: 'timing',
        duration: 100,
        controlPoints: [0, 0, 1, 1],
      }
    );

    expect(stranger.ui.cancel(groupId)).toEqual([]);
    expect(native.cancelAnimationGroup).not.toHaveBeenCalled();
    expect(driver.__smoothClipHandle?.activeAnimationId.value).toBe(groupId);
  });

  it('samples an unfinished completion before releasing matching handles', () => {
    const driver = createDriver(secondPresentation);
    const onAnimationComplete = jest.fn();
    const group = useSmoothClipGroupDriver({ onAnimationComplete });
    const groupId = group.ui.animateTo(
      [
        {
          driver,
          from: secondPresentation,
          target: firstCircularPresentation,
        },
      ],
      {
        type: 'timing',
        duration: 100,
        controlPoints: [0, 0, 1, 1],
      }
    );
    native.snapshotGroup.mockReturnValue(snapshots([true, secondPresentation]));
    const controllerId = native.animateTimingGroup.mock.calls[0]?.[0] as number;

    completionListener?.({
      controllerId,
      groupId,
      finished: false,
      driverIds: [driver.__smoothClipHandle?.driverId as number],
    });

    expect(native.snapshotGroup).toHaveBeenCalledWith([
      driver.__smoothClipHandle?.driverId,
    ]);
    expect(driver.presentation.value).toEqual(
      canonicalizeClipPresentation(secondPresentation)
    );
    expect(driver.__smoothClipHandle?.activeAnimationId.value).toBe(0);
    expect(driver.__smoothClipHandle?.ownership.value).toBe(0);
    expect(onAnimationComplete).toHaveBeenCalledWith({
      groupId,
      finished: false,
    });
  });

  it('teardown freezes snapshots and clears only matching handles', () => {
    const first = createDriver(secondPresentation);
    const second = createDriver(secondPresentation);
    const onAnimationComplete = jest.fn();
    const group = useSmoothClipGroupDriver({ onAnimationComplete });
    const groupId = group.ui.animateTo(
      [
        {
          driver: first,
          from: secondPresentation,
          target: firstCircularPresentation,
        },
        {
          driver: second,
          from: secondPresentation,
          target: firstCircularPresentation,
        },
      ],
      {
        type: 'timing',
        duration: 100,
        controlPoints: [0, 0, 1, 1],
      }
    );
    native.cancelAnimationGroup.mockReturnValue(
      snapshots([true, secondPresentation], [true, secondPresentation])
    );
    second.__smoothClipHandle!.activeAnimationId.value = 999;

    mockRunCleanups();

    expect(native.cancelAnimationGroup).toHaveBeenCalledWith(groupId, 0);
    expect(first.presentation.value).toEqual(
      canonicalizeClipPresentation(secondPresentation)
    );
    expect(first.__smoothClipHandle?.activeAnimationId.value).toBe(0);
    expect(first.__smoothClipHandle?.ownership.value).toBe(0);
    expect(second.__smoothClipHandle?.activeAnimationId.value).toBe(999);
    expect(second.__smoothClipHandle?.ownership.value).toBe(1);
    return Promise.resolve()
      .then(() => Promise.resolve())
      .then(() => {
        expect(onAnimationComplete).toHaveBeenCalledWith({
          groupId,
          finished: false,
        });
      });
  });

  it('delivers native completion after a React animation Promise reaction', async () => {
    const driver = createDriver(secondPresentation);
    const order: string[] = [];
    const group = useSmoothClipGroupDriver({
      onAnimationComplete: () => order.push('callback'),
    });
    native.animateTimingGroup.mockImplementation((controllerId: unknown) => {
      queueMicrotask(() => {
        completionListener?.({
          controllerId: controllerId as number,
          groupId: 21,
          finished: true,
          driverIds: [driver.__smoothClipHandle?.driverId as number],
        });
      });
      return 21;
    });

    await group.react
      .animateTo(
        [
          {
            driver,
            from: secondPresentation,
            target: secondPresentation,
          },
        ],
        {
          type: 'timing',
          duration: 0,
          controlPoints: [0, 0, 1, 1],
        }
      )
      .then(() => order.push('promise'));

    expect(order).toEqual(['promise', 'callback']);
    expect(driver.__smoothClipHandle?.activeAnimationId.value).toBe(0);
  });
});
