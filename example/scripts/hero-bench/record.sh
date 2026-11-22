#!/bin/sh
# Records the iOS simulator or an Android emulator while argent runs a
# hero-bench flow, and reports what every card -> detail opening showed, frame
# by frame.
#
#   example/scripts/hero-bench/record.sh <udid | adb serial> <flow.yaml> <out-dir> [cells]
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
#
# A device that `adb devices` lists is recorded with `screenrecord` at
# HERO_RECORD_SIZE (default 640x1428, half the Pixel 10 Pro emulator's
# 1280x2856: at its native size the encoder falls back to a distorted
# 720x1280). The emulator's frame rate is not trustworthy, and Android has no
# native trace: there, times run from the tap marker only.
set -eu

device=$1
flow=$2
out=$3
cells=${4:-}
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"
video="$out/recording.mp4"

if adb devices 2>/dev/null | grep -q "^$device[[:space:]]*device$"; then
  platform=android
else
  platform=ios
fi

status=0
if [ "$platform" = android ]; then
  remote=/sdcard/hero-bench-recording.mp4
  adb -s "$device" shell screenrecord --size "${HERO_RECORD_SIZE:-640x1428}" \
    --bit-rate 8000000 --time-limit 0 "$remote" &
  recorder=$!
  sleep 2
  argent e2e run "$flow" --device "$device" --platform android || status=$?
  sleep 1
  # SIGINT lets screenrecord finish the file; killing adb would not.
  adb -s "$device" shell pkill -INT screenrecord || true
  wait "$recorder" || true
  sleep 1
  adb -s "$device" pull "$remote" "$video" >/dev/null
  adb -s "$device" shell rm -f "$remote"
else
  xcrun simctl io "$device" recordVideo --codec=h264 --force "$video" &
  recorder=$!
  sleep 1
  argent e2e run "$flow" --device "$device" --platform ios || status=$?
  sleep 1
  kill -INT "$recorder"
  wait "$recorder" || true
fi

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
# (Points on iOS, dp on Android; the video's pixel scale comes from its width.)
window_width=$(field 'l.windowWidth')
region=$(field '[8,l.detail.y,l.windowWidth-16,l.controlsTop-l.detail.y].join(" ")')
card=$(field '[l.card.x,l.card.y,l.card.width,l.card.height].join(",")')
detail=$(field '[8,l.detail.y,l.windowWidth-16,l.detail.height].join(",")')
marker=$(field '[l.marker.x,l.marker.y,l.marker.width,l.marker.height].join(" ")')
# The gallery bench publishes `mask`: the tiles other than the measured one.
# HERO_MASK_PAD grows each masked rect (default 1 on Android, 0 on iOS): at
# 1.5 px per dp the encoder bleeds a photo's edge a pixel or two into the 6 dp
# gutters, and the bled pixels would stretch the measured photo's box.
if [ "$platform" = android ]; then mask_pad=${HERO_MASK_PAD:-1}; else mask_pad=${HERO_MASK_PAD:-0}; fi
HERO_MASK=$(field "(l.mask||[]).map(r=>[r.x-$mask_pad,r.y-$mask_pad,r.width+2*$mask_pad,r.height+2*$mask_pad].join(',')).join(';')")
export HERO_MASK

# Compiled: a five-minute recording is about 15,000 frames.
swiftc -O "$here/analyze-frames.swift" -o "$out/analyze-frames" 2>/dev/null
# shellcheck disable=SC2086
"$out/analyze-frames" "$video" "$window_width" $region $marker \
  > "$out/frames.jsonl"
node "$here/summarize.mjs" "$out/frames.jsonl" "$card" "$detail" "$cells" \
  > "$out/summary.json"
exit "$status"
