#!/bin/sh
# Memory of the example app (a simulator process) around a hero-bench flow:
# its physical footprint before, its highest sample while the flow runs, and
# after; then `leaks`.
#
#   example/scripts/hero-bench/memory.sh <udid> <flow.yaml> <out-dir>
set -eu

device=$1
flow=$2
out=$3
mkdir -p "$out"
pid=$(pgrep -f 'SmoothClipViewExample.app/SmoothClipViewExample' | head -1)
bytes() {
  footprint -p "$pid" --noCategories -f bytes | sed -n 's/.*phys_footprint: \([0-9]*\).*/\1/p' | head -1
}

sleep 2
before=$(bytes)
footprint -p "$pid" --noCategories -f bytes --sample 0.2 > "$out/footprint.txt" 2>/dev/null &
sampler=$!
status=0
argent e2e run "$flow" --device "$device" --platform ios > "$out/flow.txt" 2>&1 || status=$?
kill "$sampler" 2>/dev/null || true
sleep 3
after=$(bytes)
peak=$(sed -n 's/.*phys_footprint: \([0-9]*\).*/\1/p' "$out/footprint.txt" | sort -n | tail -1)
leaks "$pid" > "$out/leaks.txt" 2>&1 || true
node -e '
const [before, peak, after] = process.argv.slice(1).map(Number);
const mb = (bytes) => (bytes / 1048576).toFixed(1);
console.log(`before ${mb(before)} MB | peak +${mb(peak - before)} MB | after ${after >= before ? "+" : ""}${mb(after - before)} MB`);
' "$before" "${peak:-$before}" "$after" | tee "$out/memory.txt"
grep -E 'leaks for|total leaked' "$out/leaks.txt" | tee -a "$out/memory.txt"
exit "$status"
