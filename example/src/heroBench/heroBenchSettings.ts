import { useSyncExternalStore } from 'react';

/**
 * The four cells of the hero bench (docs/hero-bench.md): Reanimated's shared
 * element transition and a SmoothClipView flight, each into a native-stack
 * push (default slide, closed with the swipe-back gesture) and into a sheet
 * (closed by dragging it down).
 */
export type HeroVariant =
  'set-push' | 'flight-push' | 'set-sheet' | 'flight-sheet';

export const HERO_VARIANTS: readonly { value: HeroVariant; label: string }[] = [
  { value: 'set-push', label: 'SET push' },
  { value: 'flight-push', label: 'Flight push' },
  { value: 'set-sheet', label: 'SET sheet' },
  { value: 'flight-sheet', label: 'Flight sheet' },
];

export const HERO_DURATION_MS = 500;
/** `Slow`: long enough to press Back in the middle of a flight. */
export const HERO_SLOW_DURATION_MS = 4000;
/** `JS block`: how long the JS thread is held from the tap. */
export const HERO_JS_BLOCK_MS = 300;

export type HeroBenchSettings = Readonly<{
  variant: HeroVariant;
  /** Main-thread time burned in every UI frame, from the moment it is set. */
  busyMs: number;
  /** Hold the JS thread for HERO_JS_BLOCK_MS from the tap. */
  jsBlock: boolean;
  slow: boolean;
}>;

let settings: HeroBenchSettings = {
  variant: 'set-push',
  busyMs: 0,
  jsBlock: false,
  slow: false,
};
const listeners = new Set<() => void>();

export function updateHeroBenchSettings(patch: Partial<HeroBenchSettings>) {
  settings = { ...settings, ...patch };
  for (const listener of listeners) listener();
}

export function isSheetVariant(variant: HeroVariant): boolean {
  return variant === 'set-sheet' || variant === 'flight-sheet';
}

export function isFlightVariant(variant: HeroVariant): boolean {
  return variant === 'flight-push' || variant === 'flight-sheet';
}

export function heroBenchDuration(current: HeroBenchSettings): number {
  return current.slow ? HERO_SLOW_DURATION_MS : HERO_DURATION_MS;
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function useHeroBenchSettings(): HeroBenchSettings {
  return useSyncExternalStore(subscribe, () => settings);
}
