import type {
  SmoothClipController,
  SmoothClipPresentation,
} from 'react-native-smooth-clip-view';

/**
 * What the flight variants' detail route needs from the list to fly the card
 * home: the card's controller and both ends of the flight in window space.
 * The list publishes it while a flight variant is selected.
 */
export type HeroFlightBridge = Readonly<{
  clip: SmoothClipController;
  /** The landed hero. */
  detail: SmoothClipPresentation;
  /** The resting card. */
  card: SmoothClipPresentation;
  /** The card in the host's own space: where the way back's last run rests. */
  rest: SmoothClipPresentation;
}>;

let bridge: HeroFlightBridge | null = null;

export function publishHeroFlight(next: HeroFlightBridge | null) {
  bridge = next;
}

export function currentHeroFlight(): HeroFlightBridge | null {
  return bridge;
}

/**
 * The detail route's hook for a cancelled dismissal gesture; the root layout
 * calls it from the navigator's `gestureCancel` event.
 */
let wayBackCancel: (() => void) | null = null;

export function setHeroWayBackCancel(cancel: (() => void) | null) {
  wayBackCancel = cancel;
}

export function cancelHeroWayBack() {
  wayBackCancel?.();
}
