#!/bin/sh
# record.sh plus the library's native [hero-trace] log stream, for timing.mjs:
# times from the hardware touch-up. Needs a build with SMOOTH_CLIP_HERO_TRACE
# (docs/hero-bench.md). The flow must open flights and SET in one recording:
# the flights calibrate the recording's clock.
#
#   example/scripts/hero-bench/trace.sh <udid> <flow.yaml> <out-dir> [cells]
set -eu

device=$1
flow=$2
out=$3
cells=${4:-}
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"

xcrun simctl spawn "$device" log stream --style compact --level default \
  --predicate 'eventMessage CONTAINS "[hero-trace]"' > "$out/trace.log" 2>/dev/null &
logger=$!
sleep 2
status=0
"$here/record.sh" "$device" "$flow" "$out" "$cells" || status=$?
sleep 1
kill "$logger" 2>/dev/null || true
node "$here/timing.mjs" "$out" "$cells" | tee "$out/timing.txt"
exit "$status"
