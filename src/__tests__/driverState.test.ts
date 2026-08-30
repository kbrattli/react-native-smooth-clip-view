import { describe, expect, it, jest } from '@jest/globals';
import type { SmoothClipDriver } from '../driverTypes';
import { createClipPresentation } from '../geometry';
import {
  attachDriverState,
  createDriverState,
  deliverDriverCompletion,
  finishDriverAnimation,
  getDriverState,
  registerDriverView,
  registerDriverViewReadiness,
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

  it('aggregates per-host readiness instead of treating registration as ready', () => {
    const driver = makeDriver(504);
    const ready = { value: 0 };
    getDriverState(driver).ready = ready as never;
    const first = registerDriverViewReadiness(driver, false);
    const second = registerDriverViewReadiness(driver, false);

    expect(ready.value).toBe(0);
    first.setReady(true);
    expect(ready.value).toBe(1);
    second.setReady(true);
    first.setReady(false);
    expect(ready.value).toBe(1);
    second.unregister();
    expect(ready.value).toBe(0);
    first.unregister();
  });
});
