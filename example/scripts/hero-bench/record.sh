#!/bin/sh
# Records the iOS simulator while argent runs a hero-bench flow, and reports
# what every card -> detail opening showed, frame by frame.
#
#   example/scripts/hero-bench/record.sh <udid> <flow.yaml> <out-dir> [cells]
#
# `cells` names the flow's cells in order, with their opening counts, for the
# per-cell medians (see summarize.mjs): `flight/0:10,set/0:10`.
#
# The recorder writes a frame whenever the screen changes, so a time gap
# longer than one display period is a frame the screen never showed.
#
# The analysis region and the card and detail rects come from the running app
# (a Debug build, through Metro on METRO_PORT, default 8081). A Release build
# has no debugger: pass HERO_LAYOUT, the JSON a Debug build of the same device
# printed here as `layout:`.
set -eu

device=$1
flow=$2
out=$3
cells=${4:-}
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"
video="$out/recording.mp4"

xcrun simctl io "$device" recordVideo --codec=h264 --force "$video" &
recorder=$!
sleep 1
status=0
argent e2e run "$flow" --device "$device" --platform ios || status=$?
sleep 1
kill -INT "$recorder"
wait "$recorder" || true

if [ -n "${HERO_LAYOUT:-}" ]; then layout=$HERO_LAYOUT; else
layout=$(argent run debugger-evaluate --device_id "${DEBUGGER_DEVICE_ID:-$device}" \
  --port "${METRO_PORT:-8081}" \
  --expression 'JSON.stringify({...globalThis.__heroBenchLayout, marker: globalThis.__heroBenchMarker})' 2>/dev/null |
  node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s.slice(s.indexOf("{")));process.stdout.write(typeof j.result==="string"?j.result:JSON.stringify(j.result))})')
fi
echo "layout: $layout"
field() {
  printf '%s' "$layout" | node -pe "const l=JSON.parse(require('fs').readFileSync(0));$1"
}
# The region leaves out 8 pt at each side of the window: iOS scales a screen
# down a little while it pushes another, which shows a bright sliver of the
# window at both edges. The detail rect is clipped to the region to match.
window_width=$(field 'l.windowWidth')
region=$(field '[8,l.detail.y,l.windowWidth-16,l.controlsTop-l.detail.y].join(" ")')
card=$(field '[l.card.x,l.card.y,l.card.width,l.card.height].join(",")')
detail=$(field '[8,l.detail.y,l.windowWidth-16,l.detail.height].join(",")')
marker=$(field '[l.marker.x,l.marker.y,l.marker.width,l.marker.height].join(" ")')
# The gallery bench publishes `mask`: the tiles other than the measured one.
HERO_MASK=$(field '(l.mask||[]).map(r=>[r.x,r.y,r.width,r.height].join(",")).join(";")')
export HERO_MASK

# Compiled: a five-minute recording is about 15,000 frames.
swiftc -O "$here/analyze-frames.swift" -o "$out/analyze-frames" 2>/dev/null
# shellcheck disable=SC2086
"$out/analyze-frames" "$video" "$window_width" $region $marker \
  > "$out/frames.jsonl"
node "$here/summarize.mjs" "$out/frames.jsonl" "$card" "$detail" "$cells" \
  > "$out/summary.json"
exit "$status"
