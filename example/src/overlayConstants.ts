import { Dimensions, Platform } from 'react-native';
import { Easing } from 'react-native-reanimated';
import { initialWindowMetrics } from 'react-native-safe-area-context';
import { ClipEasings } from 'react-native-smooth-clip-view';
import { resolveDragContentScale } from './overlayClipGeometry';
import type { ZoomCity } from './zoomCities';

const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window');

const ANIMATION_DURATION = 400;

export const OVERLAY_PHASE_OPENING = 0 as const;
export const OVERLAY_PHASE_OPEN = 1 as const;
export const OVERLAY_PHASE_CLOSING = 2 as const;

export type OverlayPhase =
  | typeof OVERLAY_PHASE_OPENING
  | typeof OVERLAY_PHASE_OPEN
  | typeof OVERLAY_PHASE_CLOSING;

export const TIMING_CONFIG = {
  duration: ANIMATION_DURATION,
  easing: Easing.out(Easing.cubic),
};

export const FAST_TIMING = {
  duration: 250,
  easing: Easing.out(Easing.cubic),
};

export const IOS_ZOOM_DURATION = 400;

export const CLOSE_TIMING_CONFIG = {
  duration: ANIMATION_DURATION,
  easing: Easing.out(Easing.cubic),
};

/**
 * Native counterparts of the JS timings above. `ClipEasings.easeOutCubic` is
 * the exact single-Bézier form of `Easing.out(Easing.cubic)`, so the native
 * clip and the RN `progress` channel run one identical curve — that lossless
 * pairing is what keeps the headers phase-locked to the window.
 */
export const NATIVE_TIMING = {
  type: 'timing',
  duration: TIMING_CONFIG.duration,
  controlPoints: ClipEasings.easeOutCubic,
} as const;

export const NATIVE_FAST_TIMING = {
  type: 'timing',
  duration: FAST_TIMING.duration,
  controlPoints: ClipEasings.easeOutCubic,
} as const;

export const MAX_TRANSLATE_Y = SCREEN_HEIGHT;
export const MIN_WIDTH = 200;
export const MIN_HEIGHT = 200;
export const DRAG_THRESHOLD = SCREEN_HEIGHT * 0.8;
// The page's expanded header box. The overlay's drag framing is derived from
// these two numbers, so they live beside the geometry rather than in the page:
// retune the header and the framing follows it.
export const EXPANDED_HEADER_HEIGHT = 250;
export const EXPANDED_HEADER_PADDING_TOP = 50;

// The reveal's own top offset and the content's downward drag travel are two
// halves of one number: clip.y adds BOTH, contentTranslateY adds only the
// travel. Their SUM is what puts the window on screen — hold it constant and
// the window lands identically at every drag depth. The SPLIT is what decides
// which slice of the page the window frames: raising TOP_CLIP_RATIO slides the
// page up inside the window by (SCREEN_HEIGHT - MIN_HEIGHT) x the delta,
// without moving the window at all.
const OVERLAY_DRAG_TRAVEL_TOTAL = 0.9;

// The page-space line the window should centre on: the expanded header's
// PADDING BOX centre. `expandedHeader` is EXPANDED_HEADER_HEIGHT tall with
// paddingTop = insetsTop + EXPANDED_HEADER_PADDING_TOP and
// justifyContent: 'center', so flexbox centres its content on exactly this
// line — for ANY content height, which keeps the framing stable however the
// header's contents change.
const INSET_TOP =
  initialWindowMetrics?.insets.top ?? (Platform.OS === 'ios' ? 47 : 24);
const HEADER_FOCUS_Y =
  (INSET_TOP + EXPANDED_HEADER_PADDING_TOP + EXPANDED_HEADER_HEIGHT) / 2;

// Solve for the split that lands HEADER_FOCUS_Y on the window's centre at a
// full drag. With A = SCREEN_HEIGHT - MIN_HEIGHT, r = TOP_CLIP_RATIO and
// k = DRAG_TRANSLATE_Y / A, a page-space point p sits at screen y `A*k + s*p`
// while the window spans `A*(r + k) .. + MIN_HEIGHT`:
//
//     A*k + s*p = A*(r + k) + MIN_HEIGHT/2
//         s*p   = A*r + MIN_HEIGHT/2
//           r   = (s*p - MIN_HEIGHT/2) / A
//
// `s` is the content scale at the moment the window stops shrinking, i.e. at
// DRAG_THRESHOLD; reading it back off the ramp keeps this in sync if the zoom
// floor ever moves. r is always > 0 (p >= 150 => s*p > MIN_HEIGHT/2), which is
// the invariant that keeps the window's top edge inside the scaled page — the
// clamp is belt-and-braces for an absurd header config.
const THRESHOLD_CONTENT_SCALE = resolveDragContentScale(
  DRAG_THRESHOLD / SCREEN_HEIGHT
);
export const TOP_CLIP_RATIO = Math.min(
  0.5,
  Math.max(
    0,
    (THRESHOLD_CONTENT_SCALE * HEADER_FOCUS_Y - MIN_HEIGHT / 2) /
      (SCREEN_HEIGHT - MIN_HEIGHT)
  )
);
export const DRAG_TRANSLATE_Y =
  (SCREEN_HEIGHT - MIN_HEIGHT) * (OVERLAY_DRAG_TRAVEL_TOTAL - TOP_CLIP_RATIO);
/** Resting corner radius of the reveal window; the drag ramps up from here. */
export const OVERLAY_SOURCE_RADIUS = 20;

/** Card metrics; the compact header is a pixel-replica of this row. */
export const CARD_HEIGHT = 100;
export const CARD_GAP = 20;
export const CARD_INSET = 20;
export const CARD_PADDING = 20;

export const cityKeyExtractor = (item: ZoomCity) => item.id;

export { SCREEN_HEIGHT, SCREEN_WIDTH };
