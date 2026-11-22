// Splits the per-frame output of analyze-frames.swift into card -> detail
// openings and reports what each one showed.
//
//   node summarize.mjs <frames.jsonl> <card x,y,w,h> <detail x,y,w,h> \
//     [cells, e.g. flight/0:10,set/0:10] [periodMs=16.667] [durationMs=500]
//
// t = 0 for an opening is the first frame that shows the bench's tap marker,
// which the card's tap worklet lights in the main-thread turn of the touch-up.
//
// A frame is classified by the hero's bounding box:
//   card    - the resting card
//   detail  - the landed hero
//   blank   - (almost) nothing but background in the region
//   moving  - anything else
//
// Per opening:
//   firstMotionMs   t of the first frame with the hero between card and detail
//   landMs          t of the first frame at the detail rect
//   frames          frames the screen showed from first motion to landing
//   fps             those frames per second of that span
//   missedFrames    display frames skipped in that span (the recorder writes
//                   a frame per screen change, so a gap longer than one
//                   period is a frame the screen never showed)
//   longestFrameMs  the longest gap between two frames in that span
//   blankFrames     frames that showed neither card nor hero
//   epochMs         the run's start as the screen shows it: every moving
//                   frame's box height is mapped back through the
//                   ease-in-out-quad curve to the time the run must have
//                   started, and the median is taken. timing.mjs calibrates
//                   the recording clock with it.
//
// With `cells`, the openings are split in order into named cells and each
// cell's median and range are printed (to stderr; stdout stays JSON). A cell
// may name its run's curve as a third field, for the epoch fit:
// `choreo/0:10:easeOutCubic` (default `easeInOutQuad`; also `linear`).
import { readFileSync } from 'node:fs';

const [file, cardArg, detailArg, cellsArg, periodArg, durationArg] =
  process.argv.slice(2);
if (!file || !cardArg || !detailArg) {
  console.error(
    'usage: summarize.mjs <frames.jsonl> <card x,y,w,h> <detail x,y,w,h> [cells] [periodMs] [durationMs]'
  );
  process.exit(2);
}
const parseRect = (value) => value.split(',').map(Number);
const card = parseRect(cardArg);
const detail = parseRect(detailArg);
const periodMs = Number(periodArg ?? 1000 / 60);
const runDurationMs = Number(durationArg ?? 500);
// Inverse of Reanimated's Easing.inOut(Easing.quad); SmoothClipView runs its
// cubic-Bezier fit (0.455, 0.03, 0.515, 0.955), within ~1% of progress.
const inverseEaseInOutQuad = (p) =>
  p < 0.5 ? Math.sqrt(p / 2) : 1 - Math.sqrt((1 - p) / 2);
// Progress -> time fraction for the other curves a cell can name.
const INVERSE_CURVES = {
  easeInOutQuad: inverseEaseInOutQuad,
  // Easing.out(Easing.cubic): p = 1 - (1 - t)^3.
  easeOutCubic: (p) => 1 - Math.cbrt(1 - p),
  linear: (p) => p,
};
const cellSpecs = cellsArg
  ? cellsArg.split(',').map((cell) => {
      const [name, size, curve = 'easeInOutQuad'] = cell.split(':');
      if (!INVERSE_CURVES[curve]) throw new Error(`unknown curve ${curve}`);
      return { name, size: Number(size), curve };
    })
  : [];
// The curve of the n-th opening, from the cell it falls in.
const curveOf = (n) => {
  let at = 0;
  for (const cell of cellSpecs) {
    at += cell.size;
    if (n < at) return INVERSE_CURVES[cell.curve];
  }
  return inverseEaseInOutQuad;
};
const frames = readFileSync(file, 'utf8')
  .trim()
  .split('\n')
  .map((line) => JSON.parse(line));

const near = (box, rect, tolerance = 4) =>
  box !== undefined &&
  box.every((value, index) => Math.abs(value - rect[index]) <= tolerance);

const cardFrames = frames.filter((frame) => near(frame.box, card));
const cardCoverage =
  cardFrames.reduce((sum, frame) => sum + frame.coverage, 0) /
  Math.max(1, cardFrames.length);

function classify(frame) {
  if (frame.coverage < cardCoverage * 0.1) return 'blank';
  if (near(frame.box, card)) return 'card';
  if (near(frame.box, detail)) return 'detail';
  return 'moving';
}

const states = frames.map((frame) => ({ ...frame, state: classify(frame) }));
const round = (value) => (value === null ? null : Number(value.toFixed(1)));

const openings = [];
for (let index = 1; index < states.length; index++) {
  const markerRose =
    (states[index - 1].marker ?? 0) < 0.5 && (states[index].marker ?? 0) >= 0.5;
  // Only openings: the marker lights on the list, with the card at rest.
  if (!markerRose || states[index - 1].state !== 'card') continue;
  const t0 = states[index].t;

  let land = index;
  while (land < states.length && states[land].state !== 'detail') land++;
  if (land >= states.length) break;

  const firstMotion = states
    .slice(index, land + 1)
    .find((frame) => frame.state === 'moving');
  let blankFrames = 0;
  for (let at = index; at <= land; at++) {
    if (states[at].state === 'blank') blankFrames++;
  }
  let missedFrames = 0;
  let longestFrameMs = 0;
  let shown = 0;
  if (firstMotion) {
    for (let at = firstMotion.frame + 1; at <= land; at++) {
      const gap = states[at].t - states[at - 1].t;
      missedFrames += Math.max(0, Math.round(gap / periodMs) - 1);
      longestFrameMs = Math.max(longestFrameMs, gap);
      shown++;
    }
  }
  const spanMs = firstMotion ? states[land].t - firstMotion.t : 0;
  const epochs = [];
  for (let at = index; at <= land; at++) {
    const box = states[at].box;
    if (states[at].state !== 'moving' || !box) continue;
    const progress = (box[3] - card[3]) / (detail[3] - card[3]);
    if (progress < 0.1 || progress > 0.9) continue;
    epochs.push(states[at].t - curveOf(openings.length)(progress) * runDurationMs);
  }
  epochs.sort((a, b) => a - b);
  const epoch = epochs.length ? epochs[Math.floor(epochs.length / 2)] : null;
  openings.push({
    t0Ms: t0,
    firstMotionMs: round(firstMotion ? firstMotion.t - t0 : null),
    landMs: round(states[land].t - t0),
    frames: shown,
    fps: spanMs > 0 ? round((shown * 1000) / spanMs) : null,
    missedFrames,
    longestFrameMs: round(longestFrameMs),
    blankFrames,
    epochMs: round(epoch === null ? null : epoch - t0),
  });
  index = land;
}

console.log(
  JSON.stringify(
    { periodMs, cardCoverage, frames: frames.length, openings },
    null,
    2
  )
);

if (cellsArg) {
  const stats = (values) => {
    const list = values.filter((v) => v !== null).sort((a, b) => a - b);
    if (!list.length) return 'n/a';
    const median = list[Math.floor(list.length / 2)];
    return `${median} (${list[0]}–${list.at(-1)})`;
  };
  let at = 0;
  for (const { name, size } of cellSpecs) {
    const group = openings.slice(at, at + size);
    at += size;
    const pick = (key) => group.map((opening) => opening[key]);
    console.error(
      `${name} n=${group.length} | first motion after marker ${stats(pick('firstMotionMs'))} ms` +
        ` | landed ${stats(pick('landMs'))} ms | fps ${stats(pick('fps'))}` +
        ` | missed ${stats(pick('missedFrames'))} (total ${pick('missedFrames').reduce((a, b) => a + b, 0)})` +
        ` | longest frame ${stats(pick('longestFrameMs'))} ms` +
        ` | blank ${pick('blankFrames').reduce((a, b) => a + b, 0)}`
    );
  }
  if (at !== openings.length) {
    console.error(`note: ${openings.length} openings found, cells cover ${at}`);
  }
}
