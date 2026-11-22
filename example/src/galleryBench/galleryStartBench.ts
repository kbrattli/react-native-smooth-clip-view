import { Easing, makeMutable } from 'react-native-reanimated';
import { ClipEasings } from 'react-native-smooth-clip-view';

/**
 * The start-latency bench switch (docs/gallery-mount-time.md), the gallery
 * hub's "Start-latency bench" button. Off by default: every variant runs its
 * usual 500 ms curve (ease-in-out-quad; choreography's cubic ease-out).
 *
 * On, for the benchmark runs only:
 * - every variant runs **choreography's curve**, 500 ms of
 *   `Easing.out(Easing.cubic)`: choreography's timed run cannot take another
 *   one, so all eight share it. Its fast start moves the photo by several
 *   points in a run's first frame, so "first changed frame" is "the run
 *   began".
 * - the tile's tap handler logs its own UI-thread time
 *   (`[gallery-tap] <performance.now() ms>`), the start of a run's start
 *   latency. On iOS that clock is the native trace's (CLOCK_UPTIME_RAW).
 *
 * The switch is read when a run is configured: by the tap worklet (flights),
 * when a detail mounts (`measure()`), when a photo renders (SET) and when a
 * variant's navigator mounts (screen-transitions). Set it on the hub, before
 * entering a variant.
 */
let startBench = false;
const startBenchUI = makeMutable(false);

export function setGalleryStartBench(on: boolean) {
  startBench = on;
  startBenchUI.set(on);
}

/** The switch, on the JS thread. */
export function isGalleryStartBench(): boolean {
  return startBench;
}

/** The switch, in a worklet. */
export function isGalleryStartBenchUI(): boolean {
  'worklet';
  return startBenchUI.get();
}

/** The bench's curve as SmoothClipView control points (exact). */
export const GALLERY_BENCH_CONTROL_POINTS = ClipEasings.easeOutCubic;
/** The bench's curve as a Reanimated easing: choreography's own. */
export const GALLERY_BENCH_EASING = Easing.out(Easing.cubic);

/**
 * Logs a tap handler's time (its `performance.now()`, taken first thing in
 * the handler). The handler schedules this on JS after its own work, so the
 * log delays nothing the variant does.
 */
export function logGalleryTap(at: number) {
  console.log(`[gallery-tap] ${at.toFixed(3)}`);
}
