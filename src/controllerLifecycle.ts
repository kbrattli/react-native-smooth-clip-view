import NativeSmoothClipModule from './NativeSmoothClipModule';

/** Destroy from the React Native runtime; native forwards to the UI thread. */
export function destroyController(controllerId: number): void {
  NativeSmoothClipModule.destroyDriver(controllerId);
}
