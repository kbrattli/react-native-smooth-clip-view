import NativeSmoothClipModule from './smoothClipNative';

type DriverCompletion = Readonly<{
  driverId: number;
  animationId: number;
  completionTag: number;
  finished: boolean;
}>;

type GroupCompletion = Readonly<{
  controllerId: number;
  groupId: number;
  completionTag: number;
  finished: boolean;
  snapshots: readonly number[];
}>;

const driverListeners = new Map<
  number,
  Set<(event: DriverCompletion) => void>
>();
const groupListeners = new Map<number, Set<(event: GroupCompletion) => void>>();
let driverSubscription: { remove(): void } | undefined;
let groupSubscription: { remove(): void } | undefined;

function ensureDriverSubscription(): void {
  driverSubscription ??= NativeSmoothClipModule.onClipAnimationComplete(
    (event) => {
      const listeners = driverListeners.get(event.driverId);
      if (!listeners) return;
      for (const listener of listeners) listener(event);
    }
  );
}

function ensureGroupSubscription(): void {
  groupSubscription ??= NativeSmoothClipModule.onClipGroupAnimationComplete(
    (event) => {
      const listeners = groupListeners.get(event.controllerId);
      if (!listeners) return;
      for (const listener of listeners) listener(event);
    }
  );
}

export function subscribeDriverCompletion(
  driverId: number,
  listener: (event: DriverCompletion) => void
): () => void {
  const listeners = driverListeners.get(driverId) ?? new Set();
  listeners.add(listener);
  driverListeners.set(driverId, listeners);
  ensureDriverSubscription();
  return () => {
    listeners.delete(listener);
    if (listeners.size === 0) driverListeners.delete(driverId);
  };
}

export function subscribeGroupCompletion(
  controllerId: number,
  listener: (event: GroupCompletion) => void
): () => void {
  const listeners = groupListeners.get(controllerId) ?? new Set();
  listeners.add(listener);
  groupListeners.set(controllerId, listeners);
  ensureGroupSubscription();
  return () => {
    listeners.delete(listener);
    if (listeners.size === 0) groupListeners.delete(controllerId);
  };
}
