# Gallery mount time: six route transitions on one photo grid

Measured 2026-11-22. One photo gallery (12 photos, 3 columns) in the example
app, opened to a detail route by six transition variants. **Mount time** is
the time from the hardware touch-up on a tile to the first recorded frame in
which the photo has moved more than 4 pt from its tile: the "Mount time"
column of `docs/hero-flight-results.md`, measured the same way.

## Results

Release build, iPhone 18 Pro simulator (iOS 27.0, 60 Hz), no load; 10 measured
openings of the same tile per variant after 3 warm-ups, all in one recording.
Median (range) in ms after the hardware touch-up; n = 10 for every cell.

| Variant                              | Teleport                | Version                               | **Mount time** (touch-up → first motion > 4 pt) | n   | Cross-check: tap marker → first motion | Fitted run start  | Landed              |
| ------------------------------------ | ----------------------- | ------------------------------------- | ----------------------------------------------- | --- | -------------------------------------- | ----------------- | ------------------- |
| SmoothClipView flight                | without                 | 0.5.4 + flights (`f0db256`)           | **54.3** (38.5–69.9)                            | 10  | 49.1 (31.7–53.3)                       | 2.2 (0.4–15.7)    | 479.9 (474.3–486.5) |
| SmoothClipView flight                | with (added by hand)    | the same, react-native-teleport 1.2.5 | **50.6** (38.6–67.0)                            | 10  | 45.0 (31.7–51.7)                       | 3.3 (−1.0–12.2)   | 477.8 (474.0–485.3) |
| Reanimated shared element transition | none (no teleport mode) | react-native-reanimated 4.8.0         | **69.8** (58.0–83.8)                            | 10  | 63.4 (51.7–73.3)                       | 25.3 (16.5–36.5)  | 501.1 (492.3–503.8) |
| react-native-screen-transitions      | without                 | 4.2.0                                 | **118.5** (92.9–145.8)                          | 10  | 106.7 (88.3–131.7)                     | 70.2 (44.6–95.8)  | 540.1 (514.6–564.1) |
| react-native-screen-transitions      | with (`handoff`)        | 4.2.0, react-native-teleport 1.2.5    | **148.2** (134.0–164.5)                         | 10  | 133.3 (116.7–151.7)                    | 99.8 (86.3–116.3) | 569.0 (555.6–584.5) |
| react-native-screen-choreography     | with (required)         | 0.9.0, react-native-teleport 1.2.5    | **59.8** (36.5–70.1) ¹                          | 10  | 46.7 (33.3–50.0)                       | 62.2 (40.5–76.0)  | 457.3 (439.9–473.4) |

¹ **Read choreography's mount time with its curve.** Its only timing run is
`Easing.out(Easing.cubic)`; every other variant runs ease-in-out-quad. An
ease-out run moves the photo about 37 pt in its first frame, where
ease-in-out-quad moves it under 1 pt and needs about 36 ms to pass 4 pt. So
choreography's first visible motion is the first frame of its run, while its
run itself starts later than every variant but screen-transitions: 62 ms
after the touch-up (fitted), against 2–3 ms for the flights and 25 ms for
SET. With the bench's curve its mount time would be about 62 + 36 ≈ 98 ms;
that is an estimate, not a measurement.

- **Mount time** is the metric of `docs/hero-flight-results.md`: the hardware
  touch-up (native trace) to the first recorded frame in which the photo's
  box differs from its tile by more than 4 pt.
- **Cross-check.** The tap marker is lit in the touch-up's main-thread turn
  and appears in the next frame, 6–13 ms (median per variant; 2–23 ms per
  run) after the touch-up. The two methods differ by exactly that: under one
  display frame for every variant's median, more than a frame for a few
  single runs. Both are in the JSON.
- **Fitted run start** maps every moving frame's photo height back through
  the variant's curve to the time its run must have started (median of the
  frames). It does not depend on how fast a curve starts, so it ranks the
  variants by when their runs begin. It assumes the photo's height follows
  the curve, which holds for all six (the rect is interpolated linearly in
  progress); for the flights it agrees with the run epochs in the trace.
- **Landed** is the first frame at the detail rect. Every run lasts 500 ms.
- No measured opening showed a blank frame or missed a display frame.

Simulator numbers compare the variants with each other on one machine. They
are not device numbers.

## The variants

Every variant is a pair of expo-router routes: a grid (`index`) and a detail
(`[id]`). They share the photos, decoded by the same expo-image view with the
same props, the tile and detail rects (`example/src/galleryBench/`), the
measured tile (row 2, column 2) and the tap: one UI-thread `Gesture.Tap` per
tile that lights the hero bench's tap marker and then calls the variant's open
function. The grid never moves; the detail's background fades in or appears
under the flying photo. Back closes every variant.

| Variant                                    | Routes                                           | Navigator                                                                                                                                                                  | The transition                                                                                                                                                                                                                                                                                                                                                                       | Teleport                                                |
| ------------------------------------------ | ------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------- |
| SmoothClipView flight                      | `app/gallery-flight/`                            | native stack, `animation: 'fade'`                                                                                                                                          | Each tile is a window-sized `SmoothClipView` with `flight`, its photo laid out at the detail rect and cropped into the tile. The tap starts the run in its worklet (`clip.ui.animateTo`, window space), then pushes; the detail's `SmoothClipFlightTarget` takes over when it lands.                                                                                                 | not used                                                |
| SmoothClipView flight + teleport           | `app/gallery-flight-teleport/`                   | the same, inside teleport's `PortalProvider`                                                                                                                               | The same flight. react-native-teleport is added by hand (the library has no teleport mode): the detail renders no photo; its target holds a `PortalHost`, and the tile's live photo is teleported into it in the transaction that lands the flight (`ready` and the Portal's `hostName` change in one UI-thread props update), and back into its host when Back starts the run home. | added by hand                                           |
| Reanimated shared element transition       | `app/gallery-set/`                               | native stack, `animation: 'fade'`                                                                                                                                          | An animated expo-image with `sharedTransitionTag` on both ends, `SharedTransition.duration(500)`, `SharedTransitionBoundary` per screen, as `hero-bench-set.tsx`.                                                                                                                                                                                                                    | none (no teleport mode)                                 |
| react-native-screen-transitions            | `app/gallery-transitions/`                       | its Blank Stack (a JS navigator), nested in the root stack                                                                                                                 | `Transition.Boundary` (group `gallery`) on the tile and on the detail; the detail's interpolator styles its boundary with `bounds().styles({ method: 'size' })`, so the photo's frame moves and resizes from tile to detail; the backdrop fades in; the tile is hidden while its copy flies.                                                                                         | without: no boundary sets `handoff` or `escapeClipping` |
| react-native-screen-transitions + teleport | `app/gallery-transitions-teleport/`              | the same                                                                                                                                                                   | The same interpolator with `handoff` on both boundaries: the tile's live photo moves into the detail's empty boundary through react-native-teleport.                                                                                                                                                                                                                                 | with: `handoff`                                         |
| react-native-screen-choreography           | `app/gallery-choreography/index.tsx`, `[id].tsx` | the app's root native stack with `ChoreographyProvider` above it, each route in a `ChoreographyScreen`, the detail with `choreographyStackOptions` (its Expo Router guide) | `defineTransition` with one `bounds` shared element and `motion: { duration: 500 }`; the tile's photo is the owner, the detail an empty `Element.Target` with `fromSource`; `useChoreographyRouter().push` with the tile's group (what `Element.Pressable` passes), `back()` to close. The library moves the live photo through its overlay with react-native-teleport.              | required                                                |

### Teleport, checked against each library

- **react-native-screen-transitions 4.2.0** lists react-native-teleport as an
  optional peer. Two boundary props use it: `handoff` (the live payload moves
  to the matching boundary) and `escapeClipping` (the boundary renders
  through a portal host to escape a clipping parent). The grid has no
  clipping parent, so `escapeClipping` would change nothing here: the "with"
  row is `handoff`. When teleport is installed, its Blank Stack always wraps
  its screens in teleport's `PortalProvider` (one idle `PortalHost`), in the
  "without" row too; no boundary teleports anything there.
- **react-native-screen-choreography 0.9.0** requires react-native-teleport
  (1.2.2 or later) and always moves the shared element with it.
- **react-native-teleport 1.2.5** is npm's `latest`.
- **SmoothClipView** has no teleport mode. At Kenneth's request a second row
  adds react-native-teleport by hand, as described above; the flight itself
  is unchanged, so both rows start the same way.
- **Reanimated** shared element transitions have no teleport mode.

## Method

The hero bench's tooling (`docs/hero-bench.md`), extended for a grid:

- **Flows.** `.argent/flows/gallery-bench/bench.yaml`: per variant, 3 warm-up
  open/close cycles (discarded), then 10 measured ones, all on the same tile,
  in one recording, the flights first. `check.yaml` is one cycle of each
  variant for the behaviour check.
- **Frames.** `record.sh` records the simulator; `analyze-frames.swift` finds
  the photo's bounding box in every frame. The grid shows 11 other photos, so
  the layout now publishes `mask` (the other tiles) and the analysis ignores
  their pixels (`HERO_MASK`); the measured photo stays visible in the dark
  gutters between tiles and outside the grid, which give its edges to the
  point. `summarize.mjs` splits the frames into openings at the tap marker.
- **Touch-up time.** A build with `SMOOTH_CLIP_HERO_TRACE=1` logs the hardware
  time of every touch-up; `trace.sh` and `timing.mjs` place the recording on
  that clock with the flights of the same recording (their run epochs are in
  the log and are fitted from their frames). `timing.mjs` now also writes
  `timing.json`, the per-run rows.
- **Cross-check.** The tap marker → first motion, from the frames alone.
- **Run start (supplementary).** `summarize.mjs` maps each moving frame's
  photo height back through the variant's curve to the time its run must
  have started (a cell names its curve: `choreo/0:10:easeOutCubic`). Unlike
  the 4 pt threshold, this does not depend on how fast a curve starts.
- **Cells.** Release build on the iPhone 18 Pro simulator
  (`E99A3C2E-3463-439A-8088-A108DB9DB535`, iOS 27.0, 60 Hz), no load (no busy
  main thread, no JS block).

```sh
UDID=E99A3C2E-3463-439A-8088-A108DB9DB535
CELLS=flight-warm/0:3,flight/0:10,flight-tp-warm/0:3,flight-tp/0:10,set-warm/0:3,set/0:10,st-warm/0:3,st/0:10,st-tp-warm/0:3,st-tp/0:10,choreo-warm/0:3:easeOutCubic,choreo/0:10:easeOutCubic
HERO_LAYOUT=$LAYOUT example/scripts/hero-bench/trace.sh $UDID .argent/flows/gallery-bench/bench.yaml /tmp/gallery $CELLS
```

`LAYOUT` is the `layout:` line a Debug build prints (`METRO_PORT=<port>`
`record.sh … check.yaml`), as for the hero bench. Frames of one opening can be
checked with `contact-sheet.swift` (every recorded frame, labelled with its
time after the marker).

## Versions

| Package                                         | Version                                            |                                                                                          |
| ----------------------------------------------- | -------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| react-native-smooth-clip-view                   | this branch (`f0db256`, flights, unreleased 0.6.0) | built from source, with `SMOOTH_CLIP_HERO_TRACE=1`                                       |
| react-native-screen-transitions                 | 4.2.0                                              | npm `latest`                                                                             |
| react-native-screen-choreography                | 0.9.0                                              | npm `latest`                                                                             |
| react-native-teleport                           | 1.2.5                                              | npm `latest`                                                                             |
| react-native-reanimated / react-native-worklets | 4.8.0 / 0.14.0                                     | npm `latest`                                                                             |
| react-native-screens                            | 4.30.1                                             | npm `latest`                                                                             |
| react-native-gesture-handler                    | 3.3.0                                              | the example's Expo SDK 58 pin (`latest` is 3.5.0)                                        |
| expo / expo-router / expo-image                 | 58.0.26 / 58.0.32 / 58.0.18                        | SDK 58; expo-router and expo-image at `latest`                                           |
| react-native / react                            | 0.88.1 / 19.3.0                                    |                                                                                          |
| @react-navigation/native                        | 7.5.2                                              | installed as screen-transitions' required peer; its Expo Router entry does not import it |
| standard-navigation                             | 0.0.8 (screen-transitions) and 0.0.5 (expo-router) |                                                                                          |

Xcode 27.2 (27B52), iOS 27.0 simulator runtime (24A434). No package is
patched (the repo's existing `@legendapp/list` patch is unrelated).

## Caveats

- **Simulator only.** These numbers compare the variants with each other on
  one Mac. They are not device numbers, and the simulator's display link
  fires a frame late once the main thread is busy at its slot.
- **Curves.** Five variants run 500 ms of ease-in-out-quad (the flights its
  cubic-Bezier fit, screen-transitions `Easing.inOut(Easing.quad)`, SET its
  default). Choreography offers only cubic ease-out for a timed run, which
  flatters a 4 pt threshold: see ¹ above and the fitted run start.
- **Navigators.** Each library runs as its docs recommend, so the navigators
  differ. The flights and SET push a native-stack route that fades in
  (`animation: 'fade'`), nested in the root stack. screen-transitions needs
  its own JavaScript navigator (Blank Stack) for bounds transitions; its
  detail fades in on the Blank Stack's backdrop. Choreography presents its
  detail as a contained transparent modal without native animation and fades
  it in itself. The grid never moves in any variant.
- **Choreography sits in the root stack.** Its Back reverse only runs when
  its provider is above the stack holding both routes (its guide's setup);
  nested in a route group it popped without animating back. Its provider is
  therefore mounted, idle, in every variant: contexts, teleport's
  `PortalProvider` with one `PortalHost`, and an idle transition host view.
- **The same tap, not the libraries' Pressables.** Every tile is a
  UI-thread `Gesture.Tap`. screen-transitions' pressable `Boundary` and
  choreography's `Element.Pressable` only forward the press to navigation
  (source bounds are measured from the boundary's own link signals), so
  passive boundaries plus the tap are equivalent.
- **App code.** The flights need app code for the way back (a run home
  started on the UI thread before the pop), and flight + teleport also moves
  the photo between its host and the target (`galleryFlights.tsx`).
  screen-transitions' interpolator hides the tile while its copy flies and
  fades the backdrop (`galleryScreenTransitions.tsx`). SET and choreography
  need none.
- **Flight + teleport close glitch.** Its opening is clean, but every close
  shows one recorded frame without the photo, 1.7–11.7 ms before the run
  home lifts it (13 of 13 closes, warm-ups included): the photo is
  teleported back into its host one commit before the lift. Closes are not
  measured; it is a limit of this hand-made integration, not of either
  library.
- **Geometry.** Square tiles (122 pt) and a square-cornered 402 × 503 pt
  detail, so no variant animates a corner radius; screen-transitions and
  choreography get `radius` / size options only to match it.
- **Masked analysis.** The other 11 photos are ignored; the measured photo is
  tracked through the dark gutters and the margins. It is exact to a point
  for a rect that grows around its tile, which every variant does here.
- **Frames.** The recorder writes a frame per screen change; a first motion
  lands on a display frame, so single runs are quantized to about 16.7 ms.
- **One recording.** All 78 openings are in one 7-minute recording, flights
  first (26 flights calibrate its clock; all 26 agree within 5 ms).

## Data

`docs/gallery-mount-time.json`: the versions, the calibration, and every run
(warm-ups marked), with the recording times of its touch-up and marker frame.
