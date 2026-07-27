import { describe, expect, it, jest } from '@jest/globals';
import type { SmoothClipDriver } from '../driverTypes';
import { createClipPresentation } from '../geometry';
import {
  attachDriverState,
  createDriverState,
  deliverDriverCompletion,
  finishDriverAnimation,
  registerDriverView,
  setDriverState,
  snapshotDriverViews,
} from '../driverState';

const initialClip = { x: 0, y: 0, width: 100, height: 80, radius: 12 };
const initialPresentation = createClipPresentation(initialClip);

function makeDriver(
  driverId: number,
  completion = jest.fn()
): SmoothClipDriver {
  const source = { value: initialPresentation } as never;
  const driver: SmoothClipDriver = {
    kind: 'hybrid',
    presentation: source,
    ui: {
      beginInteraction: () => initialPresentation,
      set: () => undefined,
      setScalars: () => undefined,
      animateTo: () => 1,
      cancel: () => initialPresentation,
    },
    react: {
      beginInteraction: async () => initialPresentation,
      set: async () => undefined,
      animateTo: async () => 1,
      cancel: async () => initialPresentation,
    },
  };
  const state = createDriverState(driverId, initialPresentation, source, {
    current: completion,
  });
  setDriverState(driver, state);
  attachDriverState(state);
  return driver;
}

describe('hybrid driver lifecycle state', () => {
  it('delivers a driver-level completion result', () => {
    const completion = jest.fn();
    makeDriver(501, completion);

    deliverDriverCompletion(501, 9, true);

    expect(completion).toHaveBeenCalledWith({ animationId: 9, finished: true });
  });

  it('marks an animation unfinished when a participating view unmounts', () => {
    const driver = makeDriver(502);
    const unregister = registerDriverView(driver);
    snapshotDriverViews(502, 10);

    unregister();

    expect(finishDriverAnimation(502, 10, true)).toBe(false);
  });

  it('does not penalize views mounted after the animation snapshot', () => {
    const driver = makeDriver(503);
    snapshotDriverViews(503, 11);
    const unregister = registerDriverView(driver);

    unregister();

    expect(finishDriverAnimation(503, 11, true)).toBe(true);
  });
});
