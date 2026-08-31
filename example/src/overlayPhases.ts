export const OVERLAY_PHASE_OPENING = 0 as const;
export const OVERLAY_PHASE_OPEN = 1 as const;
export const OVERLAY_PHASE_CLOSING = 2 as const;

export type OverlayPhase =
  | typeof OVERLAY_PHASE_OPENING
  | typeof OVERLAY_PHASE_OPEN
  | typeof OVERLAY_PHASE_CLOSING;
