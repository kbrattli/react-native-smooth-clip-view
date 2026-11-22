// Builds docs/gallery-mount-time.json from a gallery bench run of trace.sh.
//
//   node gallery-json.mjs <run-dir> <out.json> [meta.json]
//   node gallery-json.mjs --android <run-dir> <cells> <out.json> [meta.json]
//
// Reads <run-dir>/timing.json (timing.mjs) and <run-dir>/summary.json
// (summarize.mjs). Cells are named `<variant>/0` and `<variant>-warm/0`
// (bench.yaml); warm-up runs are kept and marked. `meta.json`, if given, is
// merged in at the top (versions, device, build).
//
// --android: a record.sh run on Android has no native trace, so its times run
// from the tap marker (summary.json alone; `cells` as passed to record.sh).
// Its runs and variants are merged into the existing <out.json> with
// `platform: "android"` (earlier Android entries are replaced; the iOS ones
// are kept and marked `platform: "ios"`), and `meta.json` becomes its
// top-level `android` entry.
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const stats = (values) => {
  const list = values.filter((v) => v !== null).sort((a, b) => a - b);
  if (!list.length) return null;
  const mid = Math.floor(list.length / 2);
  const median =
    list.length % 2 ? list[mid] : Number(((list[mid - 1] + list[mid]) / 2).toFixed(1));
  return { median, min: list[0], max: list.at(-1), n: list.length };
};

if (process.argv[2] === '--android') {
  const [dir, cellsArg, out, metaPath] = process.argv.slice(3);
  const { openings } = JSON.parse(readFileSync(join(dir, 'summary.json'), 'utf8'));
  const meta = metaPath ? JSON.parse(readFileSync(metaPath, 'utf8')) : {};
  const doc = JSON.parse(readFileSync(out, 'utf8'));
  const runs = [];
  let at = 0;
  for (const cellSpec of cellsArg.split(',')) {
    const [name, size] = cellSpec.split(':');
    const cell = name.replace(/\/0$/, '');
    const warmUp = cell.endsWith('-warm');
    for (let index = 0; index < Number(size); index++, at++) {
      const opening = openings[at];
      runs.push({
        platform: 'android',
        variant: warmUp ? cell.slice(0, -'-warm'.length) : cell,
        index,
        warmUp,
        // Tap marker -> first recorded frame with the photo moved > 4 dp.
        markerToFirstMotionMs: opening.firstMotionMs,
        markerToFittedRunStartMs: opening.epochMs,
        markerToLandedMs: opening.landMs,
        framesShown: opening.frames,
        missedFrames: opening.missedFrames,
        blankFrames: opening.blankFrames,
        recording: { markerMs: opening.t0Ms },
      });
    }
  }
  if (at !== openings.length) {
    throw new Error(`${openings.length} openings, cells cover ${at}`);
  }
  const keys = [...new Set(runs.filter((run) => !run.warmUp).map((run) => run.variant))];
  const variants = keys.map((key) => {
    const measured = runs.filter((run) => run.variant === key && !run.warmUp);
    const pick = (field) => stats(measured.map((run) => run[field]));
    return {
      platform: 'android',
      key,
      markerToFirstMotionMs: pick('markerToFirstMotionMs'),
      markerToFittedRunStartMs: pick('markerToFittedRunStartMs'),
      markerToLandedMs: pick('markerToLandedMs'),
      missedFrames: measured.reduce((sum, run) => sum + run.missedFrames, 0),
      blankFrames: measured.reduce((sum, run) => sum + run.blankFrames, 0),
    };
  });
  const ios = (entry) => (entry.platform ? entry : { platform: 'ios', ...entry });
  const merged = {
    ...doc,
    android: meta,
    variants: [
      ...doc.variants.filter((v) => v.platform !== 'android').map(ios),
      ...variants,
    ],
    runs: [...doc.runs.filter((r) => r.platform !== 'android').map(ios), ...runs],
  };
  writeFileSync(out, JSON.stringify(merged, null, 2) + '\n');
  console.log(
    variants
      .map(
        (v) =>
          `${v.key}: marker->motion ${v.markerToFirstMotionMs?.median} (${v.markerToFirstMotionMs?.min}–${v.markerToFirstMotionMs?.max}) n=${v.markerToFirstMotionMs?.n}` +
          ` | run start ${v.markerToFittedRunStartMs?.median} | landed ${v.markerToLandedMs?.median}` +
          ` | missed ${v.missedFrames} | blank ${v.blankFrames}`
      )
      .join('\n')
  );
  process.exit(0);
}

const [dir, out, metaPath] = process.argv.slice(2);
const timing = JSON.parse(readFileSync(join(dir, 'timing.json'), 'utf8'));
const { openings } = JSON.parse(readFileSync(join(dir, 'summary.json'), 'utf8'));
const meta = metaPath ? JSON.parse(readFileSync(metaPath, 'utf8')) : {};

const runs = timing.rows.map((row, n) => {
  const cell = row.cell.replace(/\/0$/, '');
  const warmUp = cell.endsWith('-warm');
  const opening = openings[n];
  return {
    variant: warmUp ? cell.slice(0, -'-warm'.length) : cell,
    index: row.index,
    warmUp,
    // Touch-up -> first recorded frame with the photo moved > 4 pt.
    mountMs: row.firstMotion,
    touchUpToMarkerMs: row.marker,
    markerToFirstMotionMs: row.markerToFirstMotion,
    touchUpToLandedMs: row.landed,
    touchUpToFittedRunStartMs: row.runStart,
    framesShown: opening.frames,
    missedFrames: opening.missedFrames,
    blankFrames: opening.blankFrames,
    recording: row.recording,
  };
});

const keys = [...new Set(runs.filter((run) => !run.warmUp).map((run) => run.variant))];
const variants = keys.map((key) => {
  const measured = runs.filter((run) => run.variant === key && !run.warmUp);
  const pick = (field) => stats(measured.map((run) => run[field]));
  return {
    key,
    mountMs: pick('mountMs'),
    markerToFirstMotionMs: pick('markerToFirstMotionMs'),
    touchUpToMarkerMs: pick('touchUpToMarkerMs'),
    touchUpToFittedRunStartMs: pick('touchUpToFittedRunStartMs'),
    touchUpToLandedMs: pick('touchUpToLandedMs'),
    missedFrames: measured.reduce((sum, run) => sum + run.missedFrames, 0),
    blankFrames: measured.reduce((sum, run) => sum + run.blankFrames, 0),
  };
});

writeFileSync(
  out,
  JSON.stringify(
    { ...meta, calibration: timing.calibration, variants, runs },
    null,
    2
  ) + '\n'
);
console.log(
  variants
    .map(
      (v) =>
        `${v.key}: mount ${v.mountMs?.median} (${v.mountMs?.min}–${v.mountMs?.max}) n=${v.mountMs?.n}` +
        ` | marker->motion ${v.markerToFirstMotionMs?.median}` +
        ` | run start ${v.touchUpToFittedRunStartMs?.median}`
    )
    .join('\n')
);
