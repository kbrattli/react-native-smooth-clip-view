// Android: times every tap handler from its touch-up, for the gallery bench's
// start-latency switch (docs/gallery-mount-time.md).
//
//   node input-clock.mjs <out-dir of record.sh> [cells]
//
// record.sh saves the kernel's touch events (`getevent -lt`, seconds on the
// uptime clock) and the app's log (`logcat -v monotonic`): with the switch on,
// the tile's UI-thread tap handler logs `[gallery-tap] <performance.now() ms>`,
// which on Android is the same clock in ms. Each handler is paired with the
// last touch-up (ABS_MT_TRACKING_ID ffffffff) before it. The screen recording
// shares neither clock, so frames are still timed from the tap marker.
//
// Writes <out-dir>/input-clock.json: one row per handler, in order, with
// `touchUpToHandlerMs`; with `cells`, prints each cell's median and range.
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const [dir, cellsArg] = process.argv.slice(2);
const touchUps = readFileSync(join(dir, 'getevent.log'), 'utf8')
  .split('\n')
  .filter((line) => /ABS_MT_TRACKING_ID\s+ffffffff/.test(line))
  .map((line) => Number(/\[\s*([\d.]+)\]/.exec(line)[1]))
  .sort((a, b) => a - b);
const handlers = readFileSync(join(dir, 'logcat.log'), 'utf8')
  .split('\n')
  .map((line) => /\[gallery-tap\] ([\d.]+)/.exec(line))
  .filter(Boolean)
  .map((match) => Number(match[1]) / 1000)
  .sort((a, b) => a - b);
const rows = handlers.map((handler) => {
  const touchUp = touchUps.filter((t) => t <= handler).at(-1);
  return {
    handlerS: handler,
    touchUpS: touchUp ?? null,
    touchUpToHandlerMs:
      touchUp === undefined
        ? null
        : Number(((handler - touchUp) * 1000).toFixed(2)),
  };
});
writeFileSync(
  join(dir, 'input-clock.json'),
  JSON.stringify({ touchUps: touchUps.length, rows }, null, 2) + '\n'
);
const stats = (values) => {
  const list = values.filter((v) => v !== null).sort((a, b) => a - b);
  if (!list.length) return 'n/a';
  return `${list[Math.floor(list.length / 2)]} (${list[0]}–${list.at(-1)})`;
};
console.log(`${handlers.length} handlers, ${touchUps.length} touch-ups`);
let at = 0;
for (const cell of cellsArg ? cellsArg.split(',') : [`all/0:${rows.length}`]) {
  const [name, size] = cell.split(':');
  const group = rows.slice(at, at + Number(size));
  at += Number(size);
  console.log(
    `${name} n=${group.length} | touch-up -> handler ${stats(group.map((row) => row.touchUpToHandlerMs))} ms`
  );
}
