import type { SmoothClipCapabilities } from './capabilityTypes';

export type { SmoothClipCapabilities } from './capabilityTypes';

/** Non-native/default resolver. Platform builds replace this module. */
export function getSmoothClipCapabilities(): SmoothClipCapabilities {
  return {
    presentationProtocolVersion: 2,
    groups: true,
    perCornerRadii: true,
    continuousCurve: true,
    contentScale: true,
    autonomousComplexPathAnimation: false,
  };
}
