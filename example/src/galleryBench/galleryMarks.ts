import { makeMutable } from 'react-native-reanimated';
import { scheduleOnRN } from 'react-native-worklets';

/**
 * Diagnostic phase marks for the gallery bench (docs/gallery-mount-time.md,
 * "Why teleport starts later"). Off: nothing is recorded or logged.
 *
 * On, every opening logs one `[gallery-marks]` line about a second after its
 * tap: the time of each phase in ms after the tap worklet, and the detail
 * photo's expo-image loads (time and `cacheType`; the teleport variants count
 * the teleported tile photo's). Marks come from both threads; JS and the
 * UI-thread worklet runtime read the same steady clock (`performance.now()`),
 * so they share one timeline. In a Release build the line reaches the
 * simulator's log at the info level, which `log` hides by default:
 * `xcrun simctl spawn <udid> log show --last 10m --info --predicate
 * 'eventMessage CONTAINS "[gallery-marks]"'`.
 */
export const GALLERY_MARKS = false;

const FLUSH_AFTER_MS = 1100;

type Session = {
  variant?: string;
  tap: number;
  marks: Record<string, number>;
  loads: string[];
};
let session: Session | null = null;

/** UI-thread marks already sent for the current opening. */
const sentFromUI = makeMutable<Record<string, boolean>>({});

function flush() {
  const done = session;
  session = null;
  if (!done) return;
  const marks: Record<string, number> = {};
  for (const [name, time] of Object.entries(done.marks)) {
    marks[name] = Math.round((time - done.tap) * 10) / 10;
  }
  console.log(
    `[gallery-marks] ${JSON.stringify({
      variant: done.variant,
      marks,
      loads: done.loads,
    })}`
  );
}

function record(name: string, time: number, variant?: string) {
  if (name === 'tap') {
    flush();
    session = { tap: time, marks: {}, loads: [] };
    setTimeout(flush, FLUSH_AFTER_MS);
    return;
  }
  if (!session) return;
  session.marks[name] ??= time;
  if (variant) session.variant ??= variant;
}

/** The tap worklet: starts an opening's marks. */
export function markGalleryTap() {
  'worklet';
  if (!GALLERY_MARKS) return;
  sentFromUI.set({});
  scheduleOnRN(record, 'tap', performance.now());
}

/** A UI-thread phase, recorded once per opening. */
export function markGalleryUI(name: string) {
  'worklet';
  if (!GALLERY_MARKS) return;
  const sent = sentFromUI.get();
  if (sent[name]) return;
  sentFromUI.set({ ...sent, [name]: true });
  scheduleOnRN(record, name, performance.now());
}

/** A JS-thread phase, recorded once per opening (the first call wins). */
export function markGalleryJS(name: string, variant?: string) {
  if (!GALLERY_MARKS) return;
  record(name, performance.now(), variant);
}

/** An expo-image load of the detail photo: its time and `cacheType`. */
export function markGalleryLoad(cacheType: string) {
  if (!GALLERY_MARKS || !session) return;
  session.loads.push(
    `${Math.round((performance.now() - session.tap) * 10) / 10}:${cacheType}`
  );
}
