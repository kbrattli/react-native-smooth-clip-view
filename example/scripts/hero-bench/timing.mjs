// Times every opening from the hardware touch-up, for SET and for flights.
//
//   node timing.mjs <out-dir> [cells, e.g. flight/0:10,set/0:10]
//
// Also writes <out-dir>/timing.json: the calibration and one row per opening
// (its cell, the recording time of its touch-up and of its marker frame, and
// the times below), for docs and for videos synced on the touch-up.
//
// Reads trace.log and summary.json from trace.sh. The library's trace build
// logs the hardware time of every touch (`touch-ended at=`) and the epoch of
// every run it installs (`clip-install begin= duration=`), on the uptime
// clock. The recording has its own clock. The flights tie the two: a flight's
// epoch is in the log, and summarize.mjs fits the same epoch from the frames
// it showed. The median difference is the recording's offset, and it places
// every other frame of the recording, SET's included, on the uptime clock.
//
// Per opening: the first frame that showed the hero moving and the first at
// the detail rect, in ms after the last touch-up before it.
//
// When the app logs its tap handler's time (`[gallery-tap] <ms>`: the gallery
// bench's start-latency switch; `performance.now()` in the UI-thread handler,
// the same uptime clock in ms), each opening is also timed from its handler:
// the start latency is the handler to the first frame that showed the photo
// changed (summarize.mjs `firstChangeMs`).
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const [dir, cellsArg] = process.argv.slice(2);
const events = readFileSync(join(dir, 'trace.log'), 'utf8')
  .split('\n')
  .map((line) => {
    const at = line.indexOf('[hero-trace] ');
    if (at < 0) return null;
    const rest = line.slice(at + 13).trim();
    const space = rest.indexOf(' ');
    return { t: Number(rest.slice(0, space)), label: rest.slice(space + 1) };
  })
  .filter(Boolean)
  .sort((a, b) => a.t - b.t);
// Tap handler times (s, uptime clock), from the app's JS log.
const handlers = readFileSync(join(dir, 'trace.log'), 'utf8')
  .split('\n')
  .map((line) => /\[gallery-tap\] ([\d.]+)/.exec(line))
  .filter(Boolean)
  .map((match) => Number(match[1]) / 1000)
  .sort((a, b) => a - b);
const HANDLER_SLACK_S = 0.01;
const { openings } = JSON.parse(
  readFileSync(join(dir, 'summary.json'), 'utf8')
);

const touchUps = events
  .filter((event) => event.label.startsWith('touch-ended'))
  .map((event) => Number(/at=([\d.]+)/.exec(event.label)[1]));
// The opening runs: the bench's flights last 500 ms (the way back's settling
// run lasts 100 ms).
const flightEpochs = events
  .filter((event) => /^clip-install .*duration=0\.500/.test(event.label))
  .map((event) => Number(/begin=([\d.]+)/.exec(event.label)[1]));

// An offset candidate per (flight epoch, fitted epoch) pair that agrees with
// the pairing in order; the flights are the openings whose epoch could be
// fitted and that have a run in the log.
const fitted = openings.filter((opening) => opening.epochMs !== null);
const candidates = [];
for (const epoch of flightEpochs) {
  for (const opening of fitted) {
    candidates.push((opening.t0Ms + opening.epochMs) / 1000 - epoch);
  }
}
// The true offset is the one most pairs agree on (within 5 ms).
let offset = null;
let votes = 0;
for (const candidate of candidates) {
  const agreeing = candidates.filter(
    (other) => Math.abs(other - candidate) < 0.005
  );
  if (agreeing.length > votes) {
    votes = agreeing.length;
    agreeing.sort((a, b) => a - b);
    offset = agreeing[Math.floor(agreeing.length / 2)];
  }
}
if (offset === null) {
  console.error('no flight in the recording to calibrate its clock with');
  process.exit(1);
}
console.log(
  `calibration: ${votes} flights agree on the recording's offset (${flightEpochs.length} runs logged)`
);

const rows = openings.map((opening) => {
  const uptime = (recMs) => recMs / 1000 - offset;
  const marker = uptime(opening.t0Ms);
  // The handler that lit the marker: the last one before its frame. The
  // simulator stamps that frame about 2 ms after the handler, and the
  // calibration places frames to about 2 ms, so allow 10 ms.
  const handler = handlers.filter((t) => t < marker + HANDLER_SLACK_S).at(-1);
  // The touch-up that lit the marker: the last one before its handler (or,
  // without a handler log, before its frame).
  const touchUp = touchUps
    .filter((t) => (handler === undefined ? t < marker : t <= handler))
    .at(-1);
  const after = (ms) =>
    ms === null || touchUp === undefined
      ? null
      : Number(((uptime(opening.t0Ms + ms) - touchUp) * 1000).toFixed(1));
  const fromHandler = (ms) =>
    ms === null || handler === undefined
      ? null
      : Number(((uptime(opening.t0Ms + ms) - handler) * 1000).toFixed(1));
  const recordingMs = (t) =>
    t === undefined ? null : Number(((t + offset) * 1000).toFixed(1));
  return {
    marker: after(0),
    firstMotion: after(opening.firstMotionMs),
    firstChange: after(opening.firstChangeMs ?? null),
    landed: after(opening.landMs),
    // The run's start fitted from its frames (summarize.mjs `epochMs`).
    runStart: after(opening.epochMs),
    runStartTop: after(opening.epochTopMs ?? null),
    markerToFirstMotion: opening.firstMotionMs,
    markerToFirstChange: opening.firstChangeMs ?? null,
    handler:
      handler === undefined || touchUp === undefined
        ? null
        : Number(((handler - touchUp) * 1000).toFixed(2)),
    fromHandler: {
      marker: fromHandler(0),
      firstChange: fromHandler(opening.firstChangeMs ?? null),
      firstMotion: fromHandler(opening.firstMotionMs),
      runStart: fromHandler(opening.epochMs),
      runStartTop: fromHandler(opening.epochTopMs ?? null),
      landed: fromHandler(opening.landMs),
    },
    recording: {
      markerMs: opening.t0Ms,
      touchUpMs: recordingMs(touchUp),
      handlerMs: recordingMs(handler),
    },
  };
});

const stats = (values) => {
  const list = values.filter((v) => v !== null).sort((a, b) => a - b);
  if (!list.length) return 'n/a';
  return `${list[Math.floor(list.length / 2)]} (${list[0]}–${list.at(-1)})`;
};
let at = 0;
const cells = cellsArg
  ? cellsArg.split(',').map((cell) => cell.split(':'))
  : [['all', rows.length]];
const cellRows = [];
for (const [name, size] of cells) {
  const group = rows.slice(at, at + Number(size));
  group.forEach((row, index) => cellRows.push({ cell: name, index, ...row }));
  at += Number(size);
  console.log(
    `${name} n=${group.length} | touch-up -> marker shown ${stats(group.map((row) => row.marker))} ms` +
      ` | touch-up -> first motion ${stats(group.map((row) => row.firstMotion))} ms` +
      ` | touch-up -> landed ${stats(group.map((row) => row.landed))} ms` +
      ` | touch-up -> fitted run start ${stats(group.map((row) => row.runStart))} ms`
  );
  if (group.some((row) => row.handler !== null)) {
    const h = (key) => stats(group.map((row) => row.fromHandler[key]));
    console.log(
      `${name} | touch-up -> handler ${stats(group.map((row) => row.handler))} ms` +
        ` | handler -> first change (start latency) ${h('firstChange')} ms` +
        ` | handler -> first motion > 4 ${h('firstMotion')} ms` +
        ` | handler -> run start (size) ${h('runStart')} (position) ${h('runStartTop')} ms`
    );
  }
}
writeFileSync(
  join(dir, 'timing.json'),
  JSON.stringify(
    {
      calibration: {
        offsetS: offset,
        flightsAgreeing: votes,
        runsLogged: flightEpochs.length,
      },
      rows: cellRows,
    },
    null,
    2
  ) + '\n'
);
