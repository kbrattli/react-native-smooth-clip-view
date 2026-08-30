import type { SharedValue } from 'react-native-reanimated';
import type { ClipAnimationResult, SmoothClipDriver } from './driverTypes';
import type { SmoothClipPresentation } from './geometry';

export type DriverState = {
  driverId: number;
  initialPresentation: SmoothClipPresentation;
  source: SharedValue<SmoothClipPresentation>;
  activeAnimationId?: SharedValue<number>;
  ownership?: SharedValue<number>;
  ready?: SharedValue<number>;
  onAnimationComplete: {
    current: ((result: ClipAnimationResult) => void) | undefined;
  };
  completionDeferrals: number;
  deferredCompletions: ClipAnimationResult[];
};

const states = new WeakMap<SmoothClipDriver, DriverState>();
const statesById = new Map<number, DriverState>();
let nextDriverId = Date.now() * 1024;

export function allocateDriverId(): number {
  nextDriverId += 1;
  if (!Number.isSafeInteger(nextDriverId)) nextDriverId = 1;
  return nextDriverId;
}

export function setDriverState(
  driver: SmoothClipDriver,
  state: DriverState
): void {
  // WeakMap-only: safe to call from render (discarded renders leave nothing
  // reachable) and survives effect replays so getDriverState keeps working.
  states.set(driver, state);
}

// The strong by-id index is attached in the driver hook's effect and detached
// in its cleanup, so discarded renders never leak entries and StrictMode /
// <Activity> effect replays can re-attach the same state.
export function attachDriverState(state: DriverState): void {
  statesById.set(state.driverId, state);
}

export function detachDriverState(state: DriverState): void {
  if (statesById.get(state.driverId) === state) {
    statesById.delete(state.driverId);
  }
  // Requests pending at teardown were settled by rejectDriverRequests, but
  // their completion deferrals can no longer be released: the late-scheduled
  // resolver's releaseDriverCompletions no-ops against a detached state. An
  // effect replay reattaches THIS same object, so a stale positive count
  // would queue every future completion forever. The deferrals died with
  // their requests — reset them.
  state.completionDeferrals = 0;
  state.deferredCompletions.length = 0;
}

export function createDriverState(
  driverId: number,
  initialPresentation: SmoothClipPresentation,
  source: SharedValue<SmoothClipPresentation>,
  onAnimationComplete: DriverState['onAnimationComplete'],
  activeAnimationId?: SharedValue<number>,
  ownership?: SharedValue<number>
): DriverState {
  return {
    driverId,
    initialPresentation,
    source,
    activeAnimationId,
    ownership,
    onAnimationComplete,
    completionDeferrals: 0,
    deferredCompletions: [],
  };
}

export function deliverDriverCompletion(
  driverId: number,
  animationId: number,
  finished: boolean
): void {
  const state = statesById.get(driverId);
  if (!state) return;
  const result = { animationId, finished };
  if (state.completionDeferrals > 0) {
    state.deferredCompletions.push(result);
    return;
  }
  state.onAnimationComplete.current?.(result);
}

export function deferDriverCompletions(driverId: number): void {
  const state = statesById.get(driverId);
  if (state) state.completionDeferrals += 1;
}

export function releaseDriverCompletions(driverId: number): void {
  const state = statesById.get(driverId);
  if (!state || state.completionDeferrals === 0) return;
  state.completionDeferrals -= 1;
  if (state.completionDeferrals !== 0) return;
  const deferred = state.deferredCompletions.splice(0);
  for (const result of deferred) {
    state.onAnimationComplete.current?.(result);
  }
}

export function getDriverState(driver: SmoothClipDriver): DriverState {
  const state = states.get(driver);
  if (!state) {
    throw new Error(
      '[SmoothClipView] Drivers must be created by useSmoothClipDriver.'
    );
  }
  return state;
}
