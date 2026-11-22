// Builds docs/gallery-mount-time.json from gallery bench runs.
//
//   node gallery-json.mjs <run-dir> <out.json> [meta.json]
//   node gallery-json.mjs --android <run-dir> <cells> <out.json> [meta.json]
//   node gallery-json.mjs --add <ios|android> <run-dir> <cells> <out.json> <recording> <variants>
//
// iOS (the first form): reads <run-dir>/timing.json (timing.mjs) and
// <run-dir>/summary.json (summarize.mjs) of a trace.sh run and writes the
// whole file. Cells are named `<variant>/0` and `<variant>-warm/0`
// (bench.yaml); warm-up runs are kept and marked. `meta.json`, if given, is
// merged in at the top (versions, device, build).
//
// --android: a record.sh run on Android has no native trace, so its times run
// from the tap marker (summary.json alone; `cells` as passed to record.sh).
// Its runs and variants are merged into the existing <out.json> with
// `platform: "android"` (earlier Android entries are replaced; the iOS ones
// are kept and marked `platform: "ios"`), and `meta.json` becomes its
// top-level `android` entry.
//
// --add: merges the listed `variants` (comma-separated keys) of a later
// recording of one platform (trace.sh on iOS, record.sh on Android) into
// <out.json>, replacing earlier entries of those variants on that platform.
// Each added run names its `recording.file`. The recording's other cells (the
// flights that calibrate an iOS recording) are not results: their medians go
// to a `recordings` entry, to check the session against the first recording.
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
const readJson = (path) => JSON.parse(readFileSync(path, 'utf8'));
const cellVariant = (name) => {
  const cell = name.replace(/\/0$/, '');
  const warmUp = cell.endsWith('-warm');
  return { variant: warmUp ? cell.slice(0, -'-warm'.length) : cell, warmUp };
};

/** iOS rows of a trace.sh run: times from the touch-up. */
function iosRuns(dir) {
  const timing = readJson(join(dir, 'timing.json'));
  const { openings } = readJson(join(dir, 'summary.json'));
  const runs = timing.rows.map((row, n) => {
    const opening = openings[n];
    return {
      ...cellVariant(row.cell),
      index: row.index,
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
  // Keep the key order of the first form: variant, index, warmUp, ...
  return {
    calibration: timing.calibration,
    runs: runs.map(({ variant, warmUp, index, ...rest }) => ({
      variant,
      index,
      warmUp,
      ...rest,
    })),
  };
}

function iosVariant(runs, key) {
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
}

/** Android rows of a record.sh run: times from the tap marker. */
function androidRuns(dir, cellsArg) {
  const { openings } = readJson(join(dir, 'summary.json'));
  const runs = [];
  let at = 0;
  for (const cellSpec of cellsArg.split(',')) {
    const [name, size] = cellSpec.split(':');
    const { variant, warmUp } = cellVariant(name);
    for (let index = 0; index < Number(size); index++, at++) {
      const opening = openings[at];
      runs.push({
        platform: 'android',
        variant,
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
  return runs;
}

function androidVariant(runs, key) {
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
}

const measuredKeys = (runs) => [
  ...new Set(runs.filter((run) => !run.warmUp).map((run) => run.variant)),
];
const ios = (entry) => (entry.platform ? entry : { platform: 'ios', ...entry });
const platformOf = (entry) => entry.platform ?? 'ios';

function summarize(platform, variants) {
  return variants
    .map((v) => {
      const first = platform === 'ios' ? v.mountMs : v.markerToFirstMotionMs;
      const start =
        platform === 'ios' ? v.touchUpToFittedRunStartMs : v.markerToFittedRunStartMs;
      return (
        `${platform} ${v.key}: first motion ${first?.median} (${first?.min}–${first?.max}) n=${first?.n}` +
        ` | run start ${start?.median} | blank ${v.blankFrames}`
      );
    })
    .join('\n');
}

const mode = process.argv[2];
if (mode === '--android') {
  const [dir, cellsArg, out, metaPath] = process.argv.slice(3);
  const meta = metaPath ? readJson(metaPath) : {};
  const doc = readJson(out);
  const runs = androidRuns(dir, cellsArg);
  const variants = measuredKeys(runs).map((key) => androidVariant(runs, key));
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
  console.log(summarize('android', variants));
} else if (mode === '--add') {
  const [platform, dir, cellsArg, out, recording, variantsArg] =
    process.argv.slice(3);
  if (platform !== 'ios' && platform !== 'android') {
    throw new Error('platform must be ios or android');
  }
  const keys = variantsArg.split(',');
  const doc = readJson(out);
  let runs;
  let calibration;
  if (platform === 'ios') {
    ({ runs, calibration } = iosRuns(dir));
    runs = runs.map((run) => ({ platform: 'ios', ...run }));
  } else {
    runs = androidRuns(dir, cellsArg);
  }
  runs = runs.map((run) => ({
    ...run,
    recording: { file: recording, ...run.recording },
  }));
  const variantOf = platform === 'ios' ? iosVariant : androidVariant;
  const added = keys.map((key) => {
    const variant = variantOf(runs, key);
    return platform === 'ios' ? { platform: 'ios', ...variant } : variant;
  });
  // The other cells only calibrate the recording or check the session.
  const references = measuredKeys(runs)
    .filter((key) => !keys.includes(key))
    .map((key) => {
      const variant = variantOf(runs, key);
      return {
        key,
        firstMotionMs:
          platform === 'ios' ? variant.mountMs : variant.markerToFirstMotionMs,
      };
    });
  const replaced = (entry) =>
    platformOf(entry) === platform &&
    keys.includes(entry.key ?? entry.variant);
  const merged = {
    ...doc,
    recordings: [
      ...(doc.recordings ?? []).filter((r) => r.file !== recording),
      {
        platform,
        file: recording,
        variants: keys,
        ...(calibration ? { calibration } : {}),
        references,
      },
    ],
    variants: [
      ...doc.variants.map(ios).filter((v) => !replaced(v)),
      ...added,
    ],
    runs: [
      ...doc.runs.map(ios).filter((r) => !replaced(r)),
      ...runs.filter((run) => keys.includes(run.variant)),
    ],
  };
  writeFileSync(out, JSON.stringify(merged, null, 2) + '\n');
  console.log(summarize(platform, added));
  console.log(
    references
      .map(
        (r) =>
          `${platform} ${r.key} (reference only): first motion ${r.firstMotionMs?.median} (${r.firstMotionMs?.min}–${r.firstMotionMs?.max})`
      )
      .join('\n')
  );
} else {
  const [dir, out, metaPath] = process.argv.slice(2);
  const meta = metaPath ? readJson(metaPath) : {};
  const { runs, calibration } = iosRuns(dir);
  const variants = measuredKeys(runs).map((key) => iosVariant(runs, key));
  writeFileSync(
    out,
    JSON.stringify({ ...meta, calibration, variants, runs }, null, 2) + '\n'
  );
  console.log(summarize('ios', variants));
}
