import type { SharedValue } from 'react-native-reanimated';

/**
 * Leave the native event task before changing React lifecycle state. Consumer
 * callbacks stay on the React Native runtime and are never retained by UI.
 */
export function completeAfterNativeLanding(callback: () => void): void {
  requestAnimationFrame(callback);
}

export function revealSourceAfterNativeLanding(
  hiddenIndex: SharedValue<number>,
  callback: () => void
): void {
  hiddenIndex.set(-1);
  requestAnimationFrame(callback);
}

export function completeAfterNativeLandingWithValue<Value>(
  callback: (value: Value) => void,
  value: Value
): void {
  requestAnimationFrame(() => callback(value));
}
