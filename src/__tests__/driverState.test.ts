import { describe, expect, it, jest } from '@jest/globals';
import type { SmoothClipDriver } from '../driverTypes';
import { createClipPresentation } from '../geometry';
import {
  attachDriverState,
  createDriverState,
  deliverDriverCompletion,
  setDriverState,
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
      setPresentationScalars: () => undefined,
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
});
