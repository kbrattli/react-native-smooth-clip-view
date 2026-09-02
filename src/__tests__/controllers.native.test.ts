import { describe, expect, it, jest } from '@jest/globals';
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
    setClipPresentation: jest.fn(),
    beginGroupInteraction: jest.fn(),
    snapshotGroup: jest.fn(),
    setClipPresentationBatch: jest.fn(() => true),
    animateTimingGroup: jest.fn(() => 11),
    animateSpringGroup: jest.fn(() => 12),
    cancelAnimationGroup: jest.fn(),
    onClipGroupAnimationComplete: jest.fn(
      (listener: typeof completionListener) => {
        completionListener = listener;
        return { remove: jest.fn() };
      }
    ),
  },
}));

jest.mock('../controllerLifecycle', () => ({
  destroyController: jest.fn(),
}));

import { useSmoothClipController } from '../controllers.native';
import mockNativeModule from '../smoothClipNative';

const initial: SmoothClipPresentation = {
  clip: { x: 0, y: 0, width: 100, height: 80, radius: 12 },
  contentTranslateX: 0,
  contentTranslateY: 0,
};

const target: SmoothClipPresentation = {
  clip: { x: -40, y: 120, width: 180, height: 90, radius: 20 },
  contentTranslateX: 40,
  contentTranslateY: -120,
  contentScale: 0.8,
};

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

function snapshotPacket(value: SmoothClipPresentation): number[] {
  return [1, ...presentationPacket(canonicalizeClipPresentation(value)!)];
}

describe('useSmoothClipController', () => {
  it('uses the shared one-member batch path for streamed frames', () => {
    const controller = useSmoothClipController(initial);
    native.setClipPresentationBatch.mockClear();

    controller.ui.setFrame(target);

    expect(native.setClipPresentationBatch).toHaveBeenCalledTimes(1);
    const packet = native.setClipPresentationBatch.mock
      .calls[0]?.[0] as number[];
    expect(packet).toHaveLength(22);
    expect(packet.slice(1, 5)).toEqual([-40, 120, 180, 90]);
  });

  it('routes UI completion through the stable React callback', () => {
    const complete = jest.fn();
    const controller = useSmoothClipController(initial, {
      onAnimationComplete: complete,
    });
    native.animateTimingGroup.mockClear();

    expect(controller.ui.animateTo(target, timing, 7)).not.toBeNull();
    const call = native.animateTimingGroup.mock.calls[0] as unknown[];
    expect(call[8]).toBe(7);

    completionListener?.({
      controllerId: call[0] as number,
      groupId: 11,
      completionTag: 7,
      finished: true,
      snapshots: [],
    });
    expect(complete).toHaveBeenCalledWith({
      completionTag: 7,
      finished: true,
    });
  });

  it('rejects invalid public completion tags synchronously', () => {
    const controller = useSmoothClipController(initial);
    native.animateTimingGroup.mockClear();

    expect(controller.ui.animateTo(target, timing, 1.5)).toBeNull();
    expect(controller.ui.animateTo(target, timing, -1)).toBeNull();
    expect(native.animateTimingGroup).not.toHaveBeenCalled();
  });

  it('returns the current presentation when cancelling a stale UI run', () => {
    const controller = useSmoothClipController(initial);
    native.animateTimingGroup.mockReturnValueOnce(51);
    native.cancelAnimationGroup.mockReturnValueOnce([]);
    native.snapshotGroup.mockReturnValueOnce(snapshotPacket(target));
    const run = controller.ui.animateTo(target, timing);

    expect(run).not.toBeNull();
    expect(controller.ui.cancel(run!)).toEqual(
      canonicalizeClipPresentation(target)
    );
    expect(native.cancelAnimationGroup).toHaveBeenCalledWith(51, 0);
    expect(native.snapshotGroup).toHaveBeenCalledTimes(1);
  });

  it('correlates synchronous React completion without exposing an id', async () => {
    const complete = jest.fn();
    const controller = useSmoothClipController(initial, {
      onAnimationComplete: complete,
    });
    native.animateTimingGroup.mockImplementationOnce((...args: unknown[]) => {
      completionListener?.({
        controllerId: args[0] as number,
        groupId: 41,
        completionTag: args[8] as number,
        finished: true,
        snapshots: [],
      });
      return 41;
    });

    const run = controller.react.animateTo(target, timing);

    await expect(run.finished).resolves.toBe(true);
    expect(complete).toHaveBeenCalledWith({ finished: true });
    expect(Object.keys(run).sort()).toEqual(['cancel', 'finished']);
  });
});
