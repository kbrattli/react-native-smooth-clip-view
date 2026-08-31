import NativeSmoothClipModule from './smoothClipNative';
import type { SmoothClipCapabilities } from './capabilityTypes';

let cached: SmoothClipCapabilities | undefined;

export function getSmoothClipCapabilities(): SmoothClipCapabilities {
  if (cached) return cached;
  let autonomousComplexPathAnimation = false;
  try {
    autonomousComplexPathAnimation =
      NativeSmoothClipModule.supportsAutonomousComplexPathAnimation() === true;
  } catch {
    autonomousComplexPathAnimation = false;
  }
  cached = {
    autonomousComplexPathAnimation,
  };
  return cached;
}
