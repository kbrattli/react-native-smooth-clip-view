import { describe, expect, it, jest } from '@jest/globals';
import type { ClipAnimationResult, SmoothClipDriver } from '../driverTypes';
import {
  attachDriverState,
  createDriverState,
  deliverDriverCompletion,
  detachDriverState,
  getDriverState,
  setDriverState,
} from '../driverState';
import { createClipPresentation } from '../geometry';
import {
  createReactRequest,
  rejectDriverRequests,
  resolveReactRequest,
} from '../reactRequests';

const initial = createClipPresentation({
  x: 0,
  y: 0,
  width: 100,
  height: 80,
  radius: 12,
});

function registerDriver(
  driverId: number,
  completion: (result: ClipAnimationResult) => void = jest.fn()
) {
  const source = { value: initial } as never;
  const driver = {
    kind: 'hybrid',
    presentation: source,
    ui: {},
    react: {},
  } as unknown as SmoothClipDriver;
  const state = createDriverState(driverId, initial, source, {
    current: completion,
  });
  setDriverState(driver, state);
  attachDriverState(state);
  return driver;
}

describe('asynchronous React driver requests', () => {
  it('resolves an immediate animation request before its completion callback', async () => {
    const order: string[] = [];
    const driver = registerDriver(701, () => order.push('completion'));
    const { requestId, promise } = createReactRequest<number>(701, true);
    const observed = promise.then((value) => {
      order.push(`resolved:${value}`);
    });

    deliverDriverCompletion(701, 17, true);
    resolveReactRequest(701, requestId, 17, true);
    await observed;
    await Promise.resolve();

    expect(order).toEqual(['resolved:17', 'completion']);
    detachDriverState(getDriverState(driver));
  });

  it('rejects pending calls deterministically when the hook is destroyed', async () => {
    const driver = registerDriver(702);
    const { promise } = createReactRequest(702);

    rejectDriverRequests(702);

    await expect(promise).rejects.toThrow('Driver was destroyed');
    detachDriverState(getDriverState(driver));
  });
});
