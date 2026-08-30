import {
  afterEach,
  beforeEach,
  describe,
  expect,
  it,
  jest,
} from '@jest/globals';
import type { SmoothClipDriver } from '../driverTypes';
import {
  canonicalizeClipPresentation,
  type SmoothClipPresentation,
} from '../geometry';

var mockGroupsSupported: boolean | undefined;

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

jest.mock('../capabilities', () => ({
  getSmoothClipCapabilities: () => ({
    presentationProtocolVersion: 2,
    groups: mockGroupsSupported ?? true,
    perCornerRadii: true,
    continuousCurve: true,
    contentScale: true,
    autonomousComplexPathAnimation: true,
  }),
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
    beginGroupInteractionV2: jest.fn(),
    snapshotGroupV2: jest.fn(),
    setClipPresentationBatchV2: jest.fn(() => true),
    animateTimingGroupV2: jest.fn(() => 21),
    animateSpringGroupV2: jest.fn(() => 22),
    animateKeyframesGroupV2: jest.fn(() => 23),
    cancelAnimationGroupV2: jest.fn(),
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
  beginGroupInteractionV2: jest.Mock;
  snapshotGroupV2: jest.Mock;
  setClipPresentationBatchV2: jest.Mock;
  animateTimingGroupV2: jest.Mock;
  animateSpringGroupV2: jest.Mock;
  animateKeyframesGroupV2: jest.Mock;
  cancelAnimationGroupV2: jest.Mock;
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
  const clip = presentation.clip;
  return [
    clip.x,
    clip.y,
    clip.width,
    clip.height,
    clip.topLeftRadius ?? clip.radius,
    clip.topRightRadius ?? clip.radius,
    clip.bottomRightRadius ?? clip.radius,
    clip.bottomLeftRadius ?? clip.radius,
    clip.curve === 'continuous' ? 1 : 0,
    presentation.contentTranslateX,
    presentation.contentTranslateY,
    presentation.contentScale ?? 1,
  ];
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
    ...Array.from({ length: 12 }, () => Number.NaN),
  ]).flat();
}

let nextDriverId = 100;

function createDriver(
  presentation: SmoothClipPresentation = secondPresentation
): SmoothClipDriver {
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
  } as unknown as SmoothClipDriver;
}

describe('native SmoothClip group driver', () => {
  beforeEach(() => {
    mockGroupsSupported = true;
    jest.clearAllMocks();
    completionListener = undefined;
    mockEffects.length = 0;
    native.setClipPresentationBatchV2.mockReturnValue(true);
    native.animateTimingGroupV2.mockReturnValue(21);
    native.animateSpringGroupV2.mockReturnValue(22);
    native.animateKeyframesGroupV2.mockReturnValue(23);
    native.cancelAnimationGroupV2.mockReturnValue([]);
  });

  it('tears down safely when running against a V1 native module', () => {
    mockGroupsSupported = false;
    let useV1GroupDriver: typeof useSmoothClipGroupDriver | undefined;
    jest.isolateModules(() => {
      useV1GroupDriver = (
        require('../groupDrivers.native') as typeof import('../groupDrivers.native')
      ).useSmoothClipGroupDriver;
    });

    useV1GroupDriver!();
    const registration = mockEffects[mockEffects.length - 1];

    expect(() => registration?.cleanup?.()).not.toThrow();
    registration!.cleanup = undefined;
    expect(native.cancelAnimationGroupV2).not.toHaveBeenCalled();
  });

  afterEach(() => {
    mockRunCleanups();
  });

  it('encodes and commits a complete batch in one V2 call', () => {
    const first = createDriver();
    const second = createDriver();
    const group = useSmoothClipGroupDriver();

    group.ui.setBatch([
      { driver: first, presentation: firstPresentation },
      { driver: second, presentation: secondPresentation },
    ]);

    expect(native.setClipPresentationBatchV2).toHaveBeenCalledWith([
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
    expect(native.setClipPresentationBatchV2).not.toHaveBeenCalled();
  });

  it('returns snapshot readiness and driver identity in input order', () => {
    const first = createDriver();
    const second = createDriver();
    native.snapshotGroupV2.mockReturnValue(
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
    native.snapshotGroupV2.mockReturnValue(unavailableSnapshots(1));
    native.beginGroupInteractionV2.mockReturnValue(unavailableSnapshots(1));
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
    native.snapshotGroupV2.mockReturnValue(
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
    expect(native.animateTimingGroupV2.mock.calls[0]?.[1]).toHaveLength(52);
    expect(first.__smoothClipHandle?.activeAnimationId.value).toBe(21);
    const controllerId = native.animateTimingGroupV2.mock
      .calls[0]?.[0] as number;
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

  it('uses keyframe stride 13 and rejects inconsistent frame zero', () => {
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
    expect(native.animateKeyframesGroupV2.mock.calls[0]?.[1]).toHaveLength(53);
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
    native.snapshotGroupV2.mockReturnValue(
      snapshots([true, secondPresentation])
    );
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

    const values = native.animateKeyframesGroupV2.mock
      .calls[0]?.[1] as number[];
    expect(values[1]).toBe(0);
    expect(values.slice(28, 40)).toEqual(
      presentationValues(secondPresentation)
    );
  });

  it('rejects curve changes and unproven scale springs before dispatch', () => {
    const driver = createDriver(secondPresentation);
    native.snapshotGroupV2.mockReturnValue(
      snapshots([true, secondPresentation])
    );
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
    expect(native.animateSpringGroupV2).not.toHaveBeenCalled();
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
    expect(native.animateTimingGroupV2).not.toHaveBeenCalled();
    expect(native.animateKeyframesGroupV2).not.toHaveBeenCalled();
    expect(native.cancelAnimationGroupV2).not.toHaveBeenCalled();
  });

  it('returns all participant snapshots on cancellation', () => {
    const first = createDriver();
    const second = createDriver();
    native.snapshotGroupV2.mockReturnValue(
      snapshots([true, secondPresentation], [true, secondPresentation])
    );
    native.cancelAnimationGroupV2.mockReturnValue(
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

    expect(native.cancelAnimationGroupV2).toHaveBeenCalledWith(groupId, 0);
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
    native.cancelAnimationGroupV2.mockReturnValue([]);

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
    expect(native.cancelAnimationGroupV2).not.toHaveBeenCalled();
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
    native.snapshotGroupV2.mockReturnValue(
      snapshots([true, secondPresentation])
    );
    const controllerId = native.animateTimingGroupV2.mock
      .calls[0]?.[0] as number;

    completionListener?.({
      controllerId,
      groupId,
      finished: false,
      driverIds: [driver.__smoothClipHandle?.driverId as number],
    });

    expect(native.snapshotGroupV2).toHaveBeenCalledWith([
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
    native.cancelAnimationGroupV2.mockReturnValue(
      snapshots([true, secondPresentation], [true, secondPresentation])
    );
    second.__smoothClipHandle!.activeAnimationId.value = 999;

    mockRunCleanups();

    expect(native.cancelAnimationGroupV2).toHaveBeenCalledWith(groupId, 0);
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
    native.animateTimingGroupV2.mockImplementation((controllerId: unknown) => {
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
