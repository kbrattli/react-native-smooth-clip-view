// Builds docs/gallery-mount-time.json from the gallery bench's start-latency
// recordings, one per platform (bench.yaml, docs/gallery-mount-time.md).
//
//   node gallery-json.mjs <ios-dir> <android-dir> <cells> <out.json> <meta.json>
//
// <ios-dir> is a trace.sh run: timing.json (timing.mjs) and summary.json
// (summarize.mjs). Its times run from the tap handler, placed on the native
// trace's clock. <android-dir> is a record.sh run: summary.json and
// input-clock.json (input-clock.mjs). Its frames are timed from the tap
// marker's frame, the first frame after the handler; the touch-up -> handler
// gap comes from the kernel's touch events. `cells` are the cells both runs
// were recorded with; `<variant>-warm` cells are kept as warm-ups. meta.json
// is merged in at the top (versions, devices, builds, recordings).
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const [iosDir, androidDir, cellsArg, out, metaPath] = process.argv.slice(2);
if (!iosDir || !androidDir || !cellsArg || !out || !metaPath) {
  console.error(
    'usage: gallery-json.mjs <ios-dir> <android-dir> <cells> <out.json> <meta.json>'
  );
  process.exit(2);
}
const DISPLAY_PERIOD_MS = 1000 / 60;
const readJson = (path) => JSON.parse(readFileSync(path, 'utf8'));
const stats = (values) => {
  const list = values.filter((v) => v !== null && v !== undefined);
  list.sort((a, b) => a - b);
  if (!list.length) return null;
  const mid = Math.floor(list.length / 2);
  const median =
    list.length % 2
      ? list[mid]
      : Number(((list[mid - 1] + list[mid]) / 2).toFixed(2));
  return { median, min: list[0], max: list.at(-1), n: list.length };
};

// One { variant, index, warmUp } per opening, in recording order.
const slots = [];
for (const cell of cellsArg.split(',')) {
  const [name, size] = cell.split(':');
  const base = name.replace(/\/0$/, '');
  const warmUp = base.endsWith('-warm');
  const variant = warmUp ? base.slice(0, -'-warm'.length) : base;
  for (let index = 0; index < Number(size); index++) {
    slots.push({ variant, index, warmUp });
  }
}
const check = (platform, n) => {
  if (n !== slots.length) {
    throw new Error(`${platform}: ${n} openings, cells cover ${slots.length}`);
  }
};
const firstChangeOf = (opening) =>
  opening.firstChange && {
    framesAfterMarker: opening.firstChange.framesAfterMarker,
    edgeChange: opening.firstChange.edgeChange,
    heightProgress: opening.firstChange.heightProgress,
    topProgress: opening.firstChange.topProgress,
  };

function iosRuns() {
  const timing = readJson(join(iosDir, 'timing.json'));
  const { openings } = readJson(join(iosDir, 'summary.json'));
  check('ios', openings.length);
  const runs = timing.rows.map((row, n) => {
    const opening = openings[n];
    const h = row.fromHandler;
    return {
      platform: 'ios',
      ...slots[n],
      // Handler -> first displayed frame with the photo changed.
      startLatencyMs: h.firstChange,
      touchUpToHandlerMs: row.handler,
      handlerToMarkerMs: h.marker,
      // The old mount time (first motion > 4 pt), from the handler and from
      // the touch-up.
      handlerToFirstMotionMs: h.firstMotion,
      touchUpToFirstMotionMs: row.firstMotion,
      touchUpToFirstChangeMs: row.firstChange,
      handlerToFittedRunStartMs: { size: h.runStart, position: h.runStartTop },
      handlerToLandedMs: h.landed,
      firstChange: firstChangeOf(opening),
      framesShown: opening.frames,
      missedFrames: opening.missedFrames,
      blankFrames: opening.blankFrames,
      recording: row.recording,
    };
  });
  return { calibration: timing.calibration, runs };
}

function androidRuns() {
  const { openings } = readJson(join(androidDir, 'summary.json'));
  const input = readJson(join(androidDir, 'input-clock.json'));
  check('android', openings.length);
  if (input.rows.length !== openings.length) {
    throw new Error(
      `android: ${input.rows.length} handler logs for ${openings.length} openings`
    );
  }
  return openings.map((opening, n) => ({
    platform: 'android',
    ...slots[n],
    // Marker frame (the first frame after the handler) -> first frame with
    // the photo changed, in ms and in 60 Hz display frames. (The recorder
    // writes a frame only when the screen changes, so recorded frames would
    // undercount a still screen.)
    markerToFirstChangeMs: opening.firstChangeMs,
    markerToFirstChangeFrames:
      opening.firstChangeMs === null
        ? null
        : Math.round(opening.firstChangeMs / DISPLAY_PERIOD_MS),
    touchUpToHandlerMs: input.rows[n].touchUpToHandlerMs,
    markerToFirstMotionMs: opening.firstMotionMs,
    markerToFittedRunStartMs: {
      size: opening.epochMs,
      position: opening.epochTopMs,
    },
    markerToLandedMs: opening.landMs,
    firstChange: firstChangeOf(opening),
    framesShown: opening.frames,
    missedFrames: opening.missedFrames,
    blankFrames: opening.blankFrames,
    recording: { markerMs: opening.t0Ms },
  }));
}

const variantKeys = [
  ...new Set(slots.filter((s) => !s.warmUp).map((s) => s.variant)),
];
const sum = (runs, key) => runs.reduce((total, run) => total + run[key], 0);
const summarizeIos = (runs, key) => {
  const measured = runs.filter((r) => r.variant === key && !r.warmUp);
  const pick = (get) => stats(measured.map(get));
  return {
    platform: 'ios',
    key,
    startLatencyMs: pick((r) => r.startLatencyMs),
    touchUpToHandlerMs: pick((r) => r.touchUpToHandlerMs),
    handlerToMarkerMs: pick((r) => r.handlerToMarkerMs),
    handlerToFirstMotionMs: pick((r) => r.handlerToFirstMotionMs),
    touchUpToFirstMotionMs: pick((r) => r.touchUpToFirstMotionMs),
    handlerToFittedRunStartMs: {
      size: pick((r) => r.handlerToFittedRunStartMs.size),
      position: pick((r) => r.handlerToFittedRunStartMs.position),
    },
    handlerToLandedMs: pick((r) => r.handlerToLandedMs),
    missedFrames: sum(measured, 'missedFrames'),
    blankFrames: sum(measured, 'blankFrames'),
  };
};
const summarizeAndroid = (runs, key) => {
  const measured = runs.filter((r) => r.variant === key && !r.warmUp);
  const pick = (get) => stats(measured.map(get));
  return {
    platform: 'android',
    key,
    markerToFirstChangeMs: pick((r) => r.markerToFirstChangeMs),
    markerToFirstChangeFrames: pick((r) => r.markerToFirstChangeFrames),
    touchUpToHandlerMs: pick((r) => r.touchUpToHandlerMs),
    markerToFirstMotionMs: pick((r) => r.markerToFirstMotionMs),
    markerToFittedRunStartMs: {
      size: pick((r) => r.markerToFittedRunStartMs.size),
      position: pick((r) => r.markerToFittedRunStartMs.position),
    },
    markerToLandedMs: pick((r) => r.markerToLandedMs),
    missedFrames: sum(measured, 'missedFrames'),
    blankFrames: sum(measured, 'blankFrames'),
  };
};

const ios = iosRuns();
const android = androidRuns();
const variants = [
  ...variantKeys.map((key) => summarizeIos(ios.runs, key)),
  ...variantKeys.map((key) => summarizeAndroid(android, key)),
];
writeFileSync(
  out,
  JSON.stringify(
    {
      ...readJson(metaPath),
      calibration: ios.calibration,
      variants,
      runs: [...ios.runs, ...android],
    },
    null,
    2
  ) + '\n'
);
const show = (s, digits = 1) =>
  s ? `${s.median.toFixed(digits)} (${s.min}–${s.max})` : 'n/a';
for (const v of variants) {
  console.log(
    v.platform === 'ios'
      ? `ios ${v.key}: start latency ${show(v.startLatencyMs)} | touch-up->handler ${show(v.touchUpToHandlerMs, 2)} | >4 pt ${show(v.handlerToFirstMotionMs)} | fit size ${show(v.handlerToFittedRunStartMs.size)} pos ${show(v.handlerToFittedRunStartMs.position)} | landed ${show(v.handlerToLandedMs)} | blank ${v.blankFrames} missed ${v.missedFrames}`
      : `android ${v.key}: marker->first change ${show(v.markerToFirstChangeMs)} ms, ${show(v.markerToFirstChangeFrames, 0)} frames | touch-up->handler ${show(v.touchUpToHandlerMs, 2)} | >4 dp ${show(v.markerToFirstMotionMs)} | fit size ${show(v.markerToFittedRunStartMs.size)} pos ${show(v.markerToFittedRunStartMs.position)} | landed ${show(v.markerToLandedMs)} | blank ${v.blankFrames} missed ${v.missedFrames}`
  );
}
