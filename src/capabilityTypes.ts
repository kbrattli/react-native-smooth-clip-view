export type SmoothClipCapabilities = Readonly<{
  presentationProtocolVersion: 1 | 2;
  groups: boolean;
  perCornerRadii: boolean;
  continuousCurve: boolean;
  contentScale: boolean;
  autonomousComplexPathAnimation: boolean;
}>;

export const SMOOTH_CLIP_V1_CAPABILITIES: SmoothClipCapabilities = {
  presentationProtocolVersion: 1,
  groups: false,
  perCornerRadii: false,
  continuousCurve: false,
  contentScale: false,
  autonomousComplexPathAnimation: false,
};
