import type { SmoothClipCapabilities } from './capabilityTypes';

const WEB_CAPABILITIES: SmoothClipCapabilities = {
  presentationProtocolVersion: 2,
  groups: true,
  perCornerRadii: true,
  continuousCurve: true,
  contentScale: true,
  autonomousComplexPathAnimation: false,
};

export function getSmoothClipCapabilities(): SmoothClipCapabilities {
  return WEB_CAPABILITIES;
}
