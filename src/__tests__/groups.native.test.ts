import { describe, expect, it, jest } from '@jest/globals';
import {
  createSmoothClipRef,
  unwrapSmoothClipRef,
} from '../controllerInternals';
import {
  canonicalizeClipPresentation,
  type SmoothClipPresentation,
} from '../geometry';
import { PRESENTATION_STRIDE, presentationPacket } from '../presentationCodec';

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
  beginGroupInteraction: jest.Mock;
  snapshotGroup: jest.Mock;
  setClipPresentationBatch: jest.Mock;
  animateTimingGroup: jest.Mock;
  animateSpringGroup: jest.Mock;
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
  it('rejects an invalid appearance before writing any member', () => {
    const group = useSmoothClipGroup();
    native.setClipPresentationBatch.mockClear();
    expect(() =>
      group.ui.setFrames([
        { clip: first, frame: { ...frame, rotation: '90deg', opacity: 0.5 } },
        { clip: second, frame: { ...frame, opacity: NaN } },
      ])
    ).toThrow('A group frame is invalid');
    expect(native.setClipPresentationBatch).not.toHaveBeenCalled();
  });

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
    // One id plus one presentation packet per clip.
    const stride = PRESENTATION_STRIDE + 1;
    expect(packet).toHaveLength(2 * stride);
    expect(packet[0]).toBe(unwrapSmoothClipRef(first)?.id);
    expect(packet[stride]).toBe(unwrapSmoothClipRef(second)?.id);
    expect(packet[1]).toBe(-20);
    expect(packet[stride + 1]).toBe(220);
  });

  it('marks window-space frames with a negative driver id', () => {
    const group = useSmoothClipGroup();
    native.setClipPresentationBatch.mockClear();

    group.ui.setFrames([
      { clip: first, frame: { ...frame, space: 'window' } },
      { clip: second, frame: { ...target, space: 'host' } },
    ]);

    const packet = native.setClipPresentationBatch.mock
      .calls[0]?.[0] as number[];
    const stride = PRESENTATION_STRIDE + 1;
    expect(packet[0]).toBe(-(unwrapSmoothClipRef(first)?.id ?? 0));
    expect(packet[stride]).toBe(unwrapSmoothClipRef(second)?.id);
    // The presentation itself is unchanged: native converts it.
    expect(packet[1]).toBe(-20);
  });

  it('flags a window-space animateTo target in the entry flags slot', () => {
    const group = useSmoothClipGroup();
    native.animateTimingGroup.mockClear();

    expect(
      group.ui.animateTo(
        [
          { clip: first, target: { ...target, space: 'window' } },
          { clip: second, target },
        ],
        timing
      )
    ).not.toBeNull();

    const packet = native.animateTimingGroup.mock.calls[0]?.[1] as number[];
    const stride = PRESENTATION_STRIDE * 2 + 2;
    // [driverId, flags, from, target]: bit 1 is target-in-window, and the
    // has-from bit 0 stays clear.
    expect(packet[1]).toBe(2);
    expect(packet[stride + 1]).toBe(0);
  });

  it('sends NaN as the spring velocity for inherit', () => {
    const group = useSmoothClipGroup();
    native.animateSpringGroup.mockClear();

    expect(
      group.ui.animateTo([{ clip: first, target }], {
        type: 'spring',
        velocity: 'inherit',
      })
    ).not.toBeNull();
    expect(
      group.ui.animateTo([{ clip: first, target }], {
        type: 'spring',
        velocity: 3,
      })
    ).not.toBeNull();

    const inherit = native.animateSpringGroup.mock.calls[0] as unknown[];
    const explicit = native.animateSpringGroup.mock.calls[1] as unknown[];
    // (controllerId, entries, mass, stiffness, damping, velocity, ...)
    expect(Number.isNaN(inherit[5])).toBe(true);
    expect(explicit[5]).toBe(3);
  });

  it('treats a pre-ready streamed batch rejection as a dropped frame', () => {
    const group = useSmoothClipGroup();
    native.setClipPresentationBatch.mockReturnValueOnce(false);
    // On the UI thread a snapshot answers one entry per clip.
    native.snapshotGroup.mockReturnValueOnce(snapshotPacket(frame, false));

    expect(() => group.ui.setFrames([{ clip: first, frame }])).not.toThrow();
  });

  describe('off the UI thread (runOnUISync)', () => {
    // Native answers nothing there: not a snapshot, not a run, not a frame.
    const offUIThread = /must run on the UI thread[^]*runOnUISync/;

    it('names the cause when beginInteraction gets no snapshot', () => {
      const group = useSmoothClipGroup();
      native.beginGroupInteraction.mockReturnValueOnce([]);
      native.snapshotGroup.mockReturnValueOnce([]);

      expect(() => group.ui.beginInteraction([first, second])).toThrow(
        offUIThread
      );
      expect(native.snapshotGroup).toHaveBeenLastCalledWith([
        unwrapSmoothClipRef(first)?.id,
        unwrapSmoothClipRef(second)?.id,
      ]);
    });

    it('still reports a malformed snapshot on the UI thread', () => {
      const group = useSmoothClipGroup();
      native.beginGroupInteraction.mockReturnValueOnce([]);
      native.snapshotGroup.mockReturnValueOnce(snapshotPacket(frame));

      expect(() => group.ui.beginInteraction([first])).toThrow(
        'Native returned an invalid group snapshot'
      );
    });

    it('rejects animateTo, setFrames and cancel', () => {
      const group = useSmoothClipGroup();
      native.animateTimingGroup.mockReturnValueOnce(0);
      native.snapshotGroup.mockReturnValueOnce([]);
      expect(() =>
        group.ui.animateTo([{ clip: first, target }], timing)
      ).toThrow(offUIThread);

      native.setClipPresentationBatch.mockReturnValueOnce(false);
      native.snapshotGroup.mockReturnValueOnce([]);
      expect(() => group.ui.setFrames([{ clip: first, frame }])).toThrow(
        offUIThread
      );

      native.animateTimingGroup.mockReturnValueOnce(93);
      const handle = group.ui.animateTo([{ clip: first, target }], timing);
      expect(handle).not.toBeNull();
      native.cancelAnimationGroup.mockReturnValueOnce([]);
      native.snapshotGroup.mockReturnValueOnce([]);
      expect(() => group.ui.cancel(handle!)).toThrow(offUIThread);
    });

    it('keeps a rejected run on the UI thread a null handle', () => {
      const group = useSmoothClipGroup();
      native.animateTimingGroup.mockReturnValueOnce(0);
      native.snapshotGroup.mockReturnValueOnce(snapshotPacket(frame));

      expect(group.ui.animateTo([{ clip: first, target }], timing)).toBeNull();
    });
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

  it('stamps a run with the frame timestamp on every platform', () => {
    const group = useSmoothClipGroup();
    const runtime = globalThis as { __frameTimestamp?: number };
    runtime.__frameTimestamp = 123456.5;
    try {
      expect(
        group.ui.animateTo([{ clip: first, target }], timing)
      ).not.toBeNull();
    } finally {
      delete runtime.__frameTimestamp;
    }
    const call = native.animateTimingGroup.mock.calls.at(-1) as unknown[];
    expect(call.at(-1)).toBe(123456.5);
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

  it('returns current snapshots when cancelling a stale run', () => {
    const group = useSmoothClipGroup();
    native.animateTimingGroup.mockReturnValueOnce(91);
    native.cancelAnimationGroup.mockReturnValueOnce([]);
    native.snapshotGroup.mockReturnValueOnce(snapshotPacket(target));
    const handle = group.ui.animateTo([{ clip: first, target }], timing);

    expect(handle).not.toBeNull();
    expect(group.ui.cancel(handle!)).toEqual([
      {
        clip: first,
        frame: canonicalizeClipPresentation(target),
        ready: true,
      },
    ]);
    expect(native.cancelAnimationGroup).toHaveBeenCalledWith(91, 0);
    expect(native.snapshotGroup).toHaveBeenCalledWith([
      unwrapSmoothClipRef(first)?.id,
    ]);
  });

  it('does not cancel a run owned by another group', () => {
    const owner = useSmoothClipGroup();
    const other = useSmoothClipGroup();
    native.animateTimingGroup.mockReturnValueOnce(92);
    const handle = owner.ui.animateTo([{ clip: first, target }], timing);
    native.cancelAnimationGroup.mockClear();
    native.snapshotGroup.mockClear();

    expect(handle).not.toBeNull();
    expect(other.ui.cancel(handle!)).toEqual([]);
    expect(native.cancelAnimationGroup).not.toHaveBeenCalled();
    expect(native.snapshotGroup).not.toHaveBeenCalled();
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
