// Totals the example app's CPU per thread in an Instruments time-profile
// export (the `*_raw_cpu.xml` that `argent run native-profiler-stop` writes):
// the main thread, the JS thread and everything else. The main thread's time
// is also attributed to the layers the hero bench compares: a sample counts
// toward a bucket when any frame of its backtrace matches; buckets overlap.
//
//   node cpu.mjs <raw_cpu.xml> [process-name]
//
// The process name is a regular expression; it defaults to the example app
// (`SmoothClipView Example` in a Debug build, `SmoothClipViewExample` in a
// Release one). Works for captures of one process and for argent's
// all-processes fallback alike.
import { readFileSync } from 'node:fs';

const [file, processName = 'SmoothClipView ?Example'] = process.argv.slice(2);
const processPattern = new RegExp(`\\(${processName}, pid: \\d+\\)`);
if (!file) {
  console.error('usage: profile-breakdown.mjs <raw_cpu.xml> [process-name]');
  process.exit(2);
}

const BUCKETS = {
  'Reanimated layout animations (SET)':
    /reanimated::LayoutAnimationsProxy|SharedTransition|REASharedTransition/,
  'Reanimated (any)': /reanimated::|REA[A-Z]/,
  'SmoothClipView (any)': /smoothclip::|SmoothClip/,
  'React Native mount (RCTPerformMountInstructions)':
    /RCTPerformMountInstructions/,
  'Hermes on main (UI runtime worklets)': /hermes::vm::/,
  'Core Animation commit (CA::Transaction::commit)': /CA::Transaction::commit/,
  // The test driver's own main-thread work (argent reads the view hierarchy
  // for every `await` and tap), to subtract from the total.
  'Test driver view-hierarchy reads (argent)':
    /ViewHierarchyGetFullHierarchy|^SerializeView$/,
};

const xml = readFileSync(file, 'utf8');
const threads = new Map();
const weights = new Map();
const frames = new Map();
const backtraces = new Map();

const decode = (value) =>
  value
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&amp;/g, '&');

function threadOf(row) {
  const defined = row.match(/<thread id="(\d+)" fmt="([^"]*)"/);
  if (defined) {
    threads.set(defined[1], decode(defined[2]));
    return threads.get(defined[1]);
  }
  const ref = row.match(/<thread ref="(\d+)"\/>/);
  return ref ? threads.get(ref[1]) : undefined;
}

function weightOf(row) {
  const defined = row.match(/<weight id="(\d+)"[^>]*>(\d+)<\/weight>/);
  if (defined) {
    weights.set(defined[1], Number(defined[2]));
    return weights.get(defined[1]);
  }
  const ref = row.match(/<weight ref="(\d+)"\/>/);
  return ref ? weights.get(ref[1]) : 0;
}

function backtraceOf(row) {
  const ref = row.match(/<(?:tagged-)?backtrace ref="(\d+)"\/>/);
  if (ref) return backtraces.get(ref[1]) ?? [];
  const defined = row.match(/<(?:tagged-)?backtrace id="(\d+)"[^>]*>/);
  if (!defined) return [];
  const names = [];
  const frame = /<frame (?:id="(\d+)" name="([^"]*)"|ref="(\d+)")/g;
  let match;
  while ((match = frame.exec(row)) !== null) {
    if (match[1] !== undefined) {
      frames.set(match[1], decode(match[2]));
      names.push(frames.get(match[1]));
    } else {
      names.push(frames.get(match[3]) ?? '');
    }
  }
  backtraces.set(defined[1], names);
  return names;
}

let mainNs = 0;
let jsNs = 0;
let otherNs = 0;
const bucketNs = Object.fromEntries(Object.keys(BUCKETS).map((k) => [k, 0]));
for (const row of xml.split('<row>').slice(1)) {
  const thread = threadOf(row);
  const weight = weightOf(row);
  const stack = backtraceOf(row);
  if (!thread || !processPattern.test(thread)) continue;
  if (thread.includes('JavaScript')) {
    jsNs += weight;
    continue;
  }
  if (!thread.startsWith('Main Thread')) {
    otherNs += weight;
    continue;
  }
  mainNs += weight;
  for (const [bucket, pattern] of Object.entries(BUCKETS)) {
    if (stack.some((name) => pattern.test(name))) bucketNs[bucket] += weight;
  }
}

const ms = (ns) => Number((ns / 1e6).toFixed(1));
console.log(
  JSON.stringify(
    {
      file,
      mainThreadMs: ms(mainNs),
      jsThreadMs: ms(jsNs),
      otherThreadsMs: ms(otherNs),
      mainThreadBuckets: Object.fromEntries(
        Object.entries(bucketNs).map(([k, v]) => [k, ms(v)])
      ),
    },
    null,
    2
  )
);
