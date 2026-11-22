# Hero bench: how to measure

The hero bench compares Reanimated's shared element transition (SET,
`sharedTransitionTag`) with a SmoothClipView flight (`flight` and
`SmoothClipFlightTarget`) in two scenarios. The behaviour contract of flights
is in `docs/flight-spec.md`; the results are in
`docs/hero-flight-results.md`.

## The bench

`example/src/app/hero-bench.tsx` opens one card to a detail hero. Four
variants, chosen with the buttons under the card:

| Variant        | Navigation                       | Closed by          |
| -------------- | -------------------------------- | ------------------ |
| `set-push`     | native-stack push, default slide | swipe-back gesture |
| `flight-push`  | the same push                    | swipe-back gesture |
| `set-sheet`    | `presentation: 'pageSheet'`      | dragging the sheet |
| `flight-sheet` | the same sheet                   | dragging the sheet |

- Every run is 500 ms of timing with an ease-in-out-quad curve (SET's default
  `withTiming` curve, and its cubic-Bezier fit for the flight).
- SET and the flight place the hero at the same window rects in each scenario
  (`heroLayout()` in `example/src/heroBench/heroBenchGeometry.ts`), and both
  start from the same UI-thread `Gesture.Tap` on the card.
  - The flight starts its run in that worklet (`clip.ui.animateTo`), in the
    main-thread turn that delivers the touch-up.
  - SET starts in the mount of the navigation commit, so it waits for JS.
- The flight's way back is app code, in `hero-bench-flight.tsx`. The detail
  route follows its own dismissal: `useReanimatedTransitionProgress()` from
  react-native-screens drives `beginInteraction` and `setFrame` on the card's
  controller, and a short run lands it. Back starts a run instead, because the
  route unmounts in the pop's own commit. SET needs none of this.

Switches, on the second row:

- **`Busy 14`** burns 14 ms of main-thread time in every UI frame for as long
  as it is selected (`HeroBenchProbe`), so the frame that delivers the tap is
  already busy.
- **`JS block`** holds the JS thread for 300 ms from the tap, before the
  navigation is requested.
- **`Slow`** makes every run 4 s, to press Back in the middle of a flight.

The **tap marker** is a 16 pt square in the bottom-right corner, above every
screen. The tap worklet lights it in the touch-up's main-thread turn, for both
implementations. It is t = 0 of an opening in a recording.

## Flows

argent flows are in `.argent/flows/hero-bench/`. None relaunches the app.

- `bench-push.yaml` and `bench-sheet.yaml`: 10 open/close cycles per cell, in
  this order: flight and SET with no load, both with `Busy 14`, both with
  `JS block`. The `cells` argument of the scripts below names them:
  `flight/0:10,set/0:10,flight/busy14:10,set/busy14:10,flight/jsblock:10,set/jsblock:10`.
- `profile-<set|flight>-<push|sheet>.yaml`: 10 cycles of one variant with no
  load, for CPU and memory.
- `parity-push.yaml`, `parity-sheet.yaml` and `parity-midflight.yaml`: the
  behaviour checks behind the parity table (a finished and a cancelled
  gesture, Back, and Back in the middle of a slow flight). Record the screen
  while they run and read the frames.

## Scripts

All in `example/scripts/hero-bench/`. The simulator's display is 60 Hz.

```sh
UDID=<simulator udid>
CELLS=flight/0:10,set/0:10,flight/busy14:10,set/busy14:10,flight/jsblock:10,set/jsblock:10
LAYOUT='{"card":…,"detail":…,"controlsTop":…,"windowWidth":…,"windowHeight":…,"marker":…}'
```

- **Frames** (`record.sh`). Records the screen while a flow runs.
  `analyze-frames.swift` finds the hero's bounding box in every recorded
  frame (the pixels clearly brighter than the bench's dark background), and
  `summarize.mjs` splits the frames into openings. Per opening and
  per cell it reports the first motion and the landing after the marker, the
  frames per second between them, the missed frames and the longest frame.
  The recorder writes a frame per screen change, so a gap longer than one
  display period is a frame the screen never showed.

  ```sh
  HERO_LAYOUT=$LAYOUT example/scripts/hero-bench/record.sh $UDID \
    .argent/flows/hero-bench/bench-push.yaml /tmp/hero/push $CELLS
  ```

  A Release build has no debugger, so `record.sh` needs the layout: run it
  once against a Debug build (`METRO_PORT=8082`), and pass the `layout:` line
  it prints as `HERO_LAYOUT`.

- **Timing from the touch-up** (`trace.sh`, then `timing.mjs`). Needs the
  native trace, below. The trace logs the hardware time of every touch and the
  epoch of every flight; `timing.mjs` uses the flights of a recording to place
  its frames on the same clock, so SET's frames are timed from the touch-up
  too. Run it with the same flows and cells as `record.sh`.

- **CPU** (`cpu.mjs`). Profile a `profile-*` flow with argent's native
  profiler, then total the export per thread:

  ```sh
  argent run native-profiler-start --device_id $UDID
  argent e2e run .argent/flows/hero-bench/profile-flight-push.yaml --device $UDID --platform ios
  argent run native-profiler-stop --device_id $UDID
  node example/scripts/hero-bench/cpu.mjs <…_raw_cpu.xml>
  ```

  argent reads the view hierarchy on the main thread for every `await` and
  tap. `cpu.mjs` reports that share so it can be subtracted.

- **Memory** (`memory.sh`). Samples the app's physical footprint five times a
  second around a `profile-*` flow, and runs `leaks` afterwards.

  ```sh
  example/scripts/hero-bench/memory.sh $UDID .argent/flows/hero-bench/profile-flight-push.yaml /tmp/hero/mem
  ```

## Builds

Measure a Release build. From `example/`:

```sh
xcodebuild -workspace ios/SmoothClipViewExample.xcworkspace -scheme SmoothClipViewExample \
  -configuration Release -sdk iphonesimulator -destination "id=$UDID" -derivedDataPath ios/build -quiet
xcrun simctl install $UDID ios/build/Build/Products/Release-iphonesimulator/SmoothClipViewExample.app
```

### The native trace (`SMOOTH_CLIP_HERO_TRACE`, iOS)

`trace.sh` reads the library's two `[hero-trace]` log lines: the hardware
time of every touch-up (`touch-ended`, from a `UIApplication sendEvent:`
swizzle) and the epoch of every run a host installs (`clip-install`). Both are
compiled in only with `SMOOTH_CLIP_HERO_TRACE=1` (`ios/SmoothClipHeroTrace.h`).
It is off by default, so the published library has none of it.
`SmoothClipView.podspec` sets it when `pod install` runs with it in the
environment. From `example/ios`:

```sh
SMOOTH_CLIP_HERO_TRACE=1 LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 pod install
```

Then rebuild. A plain `pod install` turns it off again. Measure CPU, memory
and frames without it.

## The gallery bench

`docs/gallery-mount-time.md` reuses these scripts for a 12-photo grid opened
by six transition variants (`app/gallery-*`, `.argent/flows/gallery-bench/`).
For it, `analyze-frames.swift` takes `HERO_MASK` (window rects whose pixels it
ignores: the other tiles, which `record.sh` reads from the layout's `mask`)
and `HERO_THRESHOLD`; a `summarize.mjs` cell can name its run's curve for the
epoch fit (`name/0:10:easeOutCubic`); `timing.mjs` also writes `timing.json`,
the per-run rows; and `contact-sheet.swift` tiles every recorded frame of a
time window into one PNG, labelled with its time.

The gallery bench also ran on the Android emulator. `record.sh` records a
device that `adb devices` lists with `adb shell screenrecord --size 640x1428`
(`HERO_RECORD_SIZE`; at the Pixel 10 Pro emulator's native 1280x2856 the
encoder falls back to a distorted 720x1280) and runs the flow with
`--platform android`. At 1.5 px per dp the encoder bleeds a photo's edge into
the 6 dp gutters, so on Android each masked tile grows by 1 dp
(`HERO_MASK_PAD`, default 1 on Android, 0 on iOS). The layout comes from a
Debug build through Metro, as on iOS (`--device_id <adb serial>`). There is no
native trace, so `trace.sh` and `timing.mjs` do not apply: Android times run
from the tap marker, and `gallery-json.mjs --android` merges them into the
JSON.

```sh
HERO_LAYOUT=$LAYOUT example/scripts/hero-bench/record.sh emulator-5554 \
  .argent/flows/gallery-bench/bench.yaml /tmp/gallery-android $CELLS
node example/scripts/hero-bench/gallery-json.mjs --android /tmp/gallery-android \
  $CELLS docs/gallery-mount-time.json <meta.json>
```

## Android

The bench runs on Android, for correctness only. The emulator's frame rate is
not trustworthy, and Android has no native trace. A page sheet is an iOS
presentation: on Android the sheet variants are full screens. The gallery
bench's Android numbers (`docs/gallery-mount-time.md`) compare its variants
with each other on the emulator only.
