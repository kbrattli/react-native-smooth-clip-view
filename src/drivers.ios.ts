// Platform re-export only — the implementation is shared with Android.
// Edit drivers.native.ts, not this file.
export { useSmoothClipDriver } from './drivers.native';
export type {
  KeyframedClipAnimation,
  SpringClipAnimation,
  TimingClipAnimation,
} from './drivers.native';
