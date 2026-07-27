import { scheduleOnUI } from 'react-native-worklets';
import { deliverDriverCompletion } from './driverState';

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
