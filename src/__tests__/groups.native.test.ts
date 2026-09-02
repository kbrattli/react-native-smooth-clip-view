import { describe, expect, it, jest } from '@jest/globals';
import {
  createSmoothClipRef,
  unwrapSmoothClipRef,
} from '../controllerInternals';
import {
  canonicalizeClipPresentation,
  type SmoothClipPresentation,
} from '../geometry';
import { presentationPacket } from '../presentationCodec';

let completionListener:
  | ((event: {
      controllerId: number;
      groupId: number;
      completionTag: number;
      finished: boolean;
      snapshots: readonly number[];
    }) => void)
  | undefined;

jest.mock('react', () => {
  const actual = jest.requireActual<typeof import('react')>('react');
  return {
    ...actual,
    useEffect: (effect: () => void | (() => void)) => {
      effect();
    },
    useRef: (initial: unknown) => ({ current: initial }),
  };
});

jest.mock('react-native-worklets', () => ({
  scheduleOnUI: (fn: (...args: never[]) => void, ...args: never[]) =>
    fn(...args),
  scheduleOnRN: (fn: (...args: never[]) => void, ...args: never[]) =>
    fn(...args),
}));

jest.mock('../smoothClipNative', () => ({
  __esModule: true,
  default: {
    beginGroupInteraction: jest.fn(),
    snapshotGroup: jest.fn(),
    setClipPresentationBatch: jest.fn(() => true),
    animateTimingGroup: jest.fn(() => 77),
    animateSpringGroup: jest.fn(() => 78),
    cancelAnimationGroup: jest.fn(),
    onClipGroupAnimationComplete: jest.fn(
      (listener: typeof completionListener) => {
        completionListener = listener;
        return { remove: jest.fn() };
      }
    ),
  },
}));

import { useSmoothClipGroup } from '../groups.native';
import mockNativeModule from '../smoothClipNative';

const frame: SmoothClipPresentation = {
  clip: { x: -20, y: 30, width: 100, height: 80, radius: 12 },
  contentTranslateX: 20,
  contentTranslateY: -30,
};
const target: SmoothClipPresentation = {
  clip: { x: 220, y: -40, width: 160, height: 140, radius: 24 },
  contentTranslateX: -220,
  contentTranslateY: 40,
};
const first = createSmoothClipRef(101);
const second = createSmoothClipRef(102);
const timing = {
  type: 'timing' as const,
  duration: 250,
  controlPoints: [0.42, 0, 0.58, 1] as const,
};

type MockNative = {
  snapshotGroup: jest.Mock;
  setClipPresentationBatch: jest.Mock;
  animateTimingGroup: jest.Mock;
  cancelAnimationGroup: jest.Mock;
};

const native = mockNativeModule as unknown as MockNative;

function snapshotPacket(value: SmoothClipPresentation, ready = true): number[] {
  return [
    ready ? 1 : 0,
    ...presentationPacket(canonicalizeClipPresentation(value)!),
  ];
}

describe('useSmoothClipGroup', () => {
  it('submits one ordered native batch for streamed frames', () => {
    const group = useSmoothClipGroup();
    native.setClipPresentationBatch.mockClear();

    group.ui.setFrames([
      { clip: first, frame },
      { clip: second, frame: target },
    ]);

    expect(native.setClipPresentationBatch).toHaveBeenCalledTimes(1);
    const packet = native.setClipPresentationBatch.mock
      .calls[0]?.[0] as number[];
    expect(packet[0]).toBe(unwrapSmoothClipRef(first)?.id);
    expect(packet[22]).toBe(unwrapSmoothClipRef(second)?.id);
    expect(packet[1]).toBe(-20);
    expect(packet[23]).toBe(220);
  });

  it('treats a pre-ready streamed batch rejection as a dropped frame', () => {
    const group = useSmoothClipGroup();
    native.setClipPresentationBatch.mockReturnValueOnce(false);

    expect(() => group.ui.setFrames([{ clip: first, frame }])).not.toThrow();
  });

  it('settles from ordered snapshots carried by the completion event', async () => {
    const group = useSmoothClipGroup();
    native.snapshotGroup.mockClear();
    const run = group.react.animateTo(
      [
        { clip: first, target: frame },
        { clip: second, target },
      ],
      timing
    );
    const controllerId = native.animateTimingGroup.mock.calls.at(
      -1
    )?.[0] as number;
    completionListener?.({
      controllerId,
      groupId: 77,
      completionTag: -1,
      finished: false,
      snapshots: [...snapshotPacket(frame), ...snapshotPacket(target, false)],
    });

    await expect(run.finished).resolves.toBe(false);
    expect(native.snapshotGroup).not.toHaveBeenCalled();
  });

  it('delivers a UI-runtime completion tag exactly once', () => {
    const complete = jest.fn();
    const group = useSmoothClipGroup({ onAnimationComplete: complete });
    const handle = group.ui.animateTo([{ clip: first, target }], timing, 19);
    expect(handle).not.toBeNull();
    const controllerId = native.animateTimingGroup.mock.calls.at(
      -1
    )?.[0] as number;
    const event = {
      controllerId,
      groupId: 77,
      completionTag: 19,
      finished: true,
      snapshots: [] as number[],
    };

    completionListener?.(event);
    completionListener?.(event);

    expect(complete).toHaveBeenCalledTimes(1);
    expect(complete).toHaveBeenCalledWith({
      completionTag: 19,
      finished: true,
    });
  });

  it('treats an empty cancel result as a stale run', () => {
    const group = useSmoothClipGroup();
    native.animateTimingGroup.mockReturnValueOnce(91);
    native.cancelAnimationGroup.mockReturnValueOnce([]);
    const handle = group.ui.animateTo([{ clip: first, target }], timing);

    expect(handle).not.toBeNull();
    expect(group.ui.cancel(handle!)).toEqual([]);
    expect(native.cancelAnimationGroup).toHaveBeenCalledWith(91, 0);
  });

  it('does not cancel a run owned by another group', () => {
    const owner = useSmoothClipGroup();
    const other = useSmoothClipGroup();
    native.animateTimingGroup.mockReturnValueOnce(92);
    const handle = owner.ui.animateTo([{ clip: first, target }], timing);
    native.cancelAnimationGroup.mockClear();

    expect(handle).not.toBeNull();
    expect(other.ui.cancel(handle!)).toEqual([]);
    expect(native.cancelAnimationGroup).not.toHaveBeenCalled();
  });

  it('correlates replacement completions without exposing native ids', async () => {
    const group = useSmoothClipGroup();
    native.animateTimingGroup.mockReturnValueOnce(81).mockReturnValueOnce(82);
    const firstRun = group.react.animateTo([{ clip: first, target }], timing);
    const firstCall = native.animateTimingGroup.mock.calls.at(-1) as unknown[];
    const secondRun = group.react.animateTo(
      [{ clip: first, target: frame }],
      timing
    );
    const secondCall = native.animateTimingGroup.mock.calls.at(-1) as unknown[];

    completionListener?.({
      controllerId: firstCall[0] as number,
      groupId: 81,
      completionTag: firstCall[8] as number,
      finished: false,
      snapshots: [],
    });
    completionListener?.({
      controllerId: secondCall[0] as number,
      groupId: 82,
      completionTag: secondCall[8] as number,
      finished: true,
      snapshots: [],
    });

    await expect(firstRun.finished).resolves.toBe(false);
    await expect(secondRun.finished).resolves.toBe(true);
  });

  it('cancel requests native freeze and settles false on completion', async () => {
    const group = useSmoothClipGroup();
    native.cancelAnimationGroup.mockReturnValueOnce(snapshotPacket(frame));
    const run = group.react.animateTo([{ clip: first, target }], timing);
    const call = native.animateTimingGroup.mock.calls.at(-1) as unknown[];

    run.cancel();
    await Promise.resolve();
    expect(native.cancelAnimationGroup).toHaveBeenCalledWith(77, 0);
    completionListener?.({
      controllerId: call[0] as number,
      groupId: 77,
      completionTag: call[8] as number,
      finished: false,
      snapshots: snapshotPacket(frame),
    });

    await expect(run.finished).resolves.toBe(false);
  });
});
