import { scheduleOnUI } from 'react-native-worklets';
import { deliverDriverCompletion } from './driverState';
import NativeSmoothClipModule from './smoothClipNative';

type DriverCompletion = Readonly<{
  driverId: number;
  animationId: number;
  finished: boolean;
}>;

type GroupCompletion = Readonly<{
  controllerId: number;
  groupId: number;
  finished: boolean;
  driverIds: readonly number[];
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
    if (driverListeners.size === 0) {
      driverSubscription?.remove();
      driverSubscription = undefined;
    }
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
    if (groupListeners.size === 0) {
      groupSubscription?.remove();
      groupSubscription = undefined;
    }
  };
}

export function completeNativeAnimation(
  driverId: number,
  animationId: number,
  finished: boolean
): void {
  deliverDriverCompletion(driverId, animationId, finished);
}

export function synchronizeNativeCompletion(
  activeAnimationId: { value: number },
  ownership: { value: number },
  animationId: number,
  _finished: boolean
): void {
  // Unfinished completions must also release ownership: native emits
  // finished:false when the last participating view unmounts or the system
  // strips the animation. Superseded ids are already filtered by the
  // active-id comparison below, so no finished-based gate is needed.
  scheduleOnUI(
    (
      active: { value: number },
      owner: { value: number },
      completedId: number
    ) => {
      'worklet';
      if (active.value !== completedId) return;
      active.value = 0;
      owner.value = 0;
    },
    activeAnimationId,
    ownership,
    animationId
  );
}
