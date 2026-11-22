# Gallery start latency: eight route transitions on one photo grid

Measured 2026-11-22. One photo gallery (12 photos, 3 columns, every photo
with 20 pt corners) in the example app, opened to a detail route by eight
transition variants. **Start latency** is the time from the tile's tap
handler to the first displayed frame in which the photo has begun to move:
the first frame whose photo box differs from the resting tile's, by any
amount above the analysis's noise (1 pt on iOS, 2 dp on Android). How far a
curve moves the photo in that frame does not change it.

For the measurement every variant runs the same curve: 500 ms of
`Easing.out(Easing.cubic)`, react-native-screen-choreography's only timed
curve, copied by the other seven (the gallery hub's **Start-latency bench**
switch; off, each keeps its usual ease-in-out). The first version of this page
measured _mount time_ (touch-up to the first frame moved more than 4 pt),
which depends on the curve: ease-in-out needs about 36 ms to move 4 pt. It is
kept below as a secondary column; the earlier tables are in git history
(`15139d1`).

## Results: iOS

Release build, iPhone 18 Pro simulator (iOS 27.0, 60 Hz), no load; 10
measured openings of tile 4 per variant after 3 warm-ups, all 104 openings in
one recording. Median (range) in ms **after the tap handler**; n = 10 for
every cell.

| Variant                               | Teleport                | **Start latency** (handler → first changed frame) | Touch-up → handler | Old mount time (handler → moved > 4 pt) | Run start, fitted: position / size | Landed              |
| ------------------------------------- | ----------------------- | ------------------------------------------------- | ------------------ | --------------------------------------- | ---------------------------------- | ------------------- |
| SmoothClipView flight                 | without                 | **3.0** (−1.6–7.1)                                | 2.0 (1.2–13.8)     | 3.6 (1.1–16.7)                          | 0.8 / 0.0                          | 397.3 (386.8–402.0) |
| SmoothClipView flight                 | with (added by hand)    | **3.5** (0.1–4.6)                                 | 6.7 (0.7–18.4)     | 4.5 (2.2–18.1)                          | 1.5 / 0.5                          | 390.4 (388.1–403.9) |
| Reanimated shared element transition  | none (no teleport mode) | **34.6** (18.6–51.7)                              | 3.9 (1.0–18.6)     | 34.6 (18.6–51.7)                        | 20.6 / 19.9                        | 417.4 (407.0–421.5) |
| Reanimated `measure()` + width/height | without                 | **50.8** (41.3–54.7)                              | 4.0 (1.8–20.1)     | 50.8 (41.3–54.7)                        | 17.1 / 16.4                        | 414.1 (398.7–419.7) |
| Reanimated `measure()` + width/height | with (added by hand)    | **41.9** (23.2–65.2) ¹                            | 6.7 (0.9–17.5)     | 41.9 (23.2–65.2)                        | 18.8 / 18.1                        | 413.2 (396.9–418.0) |
| react-native-screen-transitions       | without                 | **88.5** (71.7–106.4)                             | 3.5 (2.0–15.5)     | 88.5 (71.7–106.4)                       | 67.6 / 66.8                        | 467.6 (453.3–488.0) |
| react-native-screen-transitions       | with (`handoff`)        | **85.2** (64.8–98.9)                              | 4.5 (2.1–16.3)     | 85.2 (64.8–98.9)                        | 65.5 / 81.4                        | 483.3 (468.0–502.2) |
| react-native-screen-choreography      | with (required)         | **48.0** (41.7–49.9)                              | 3.1 (1.6–13.3)     | 48.6 (45.0–56.7)                        | 34.2 / 50.1                        | 448.9 (433.1–451.6) |

¹ 2 of the 10 openings showed one blank recorded frame (about 7 ms) before
the first changed frame: see
[the do-it-yourself hero](#the-do-it-yourself-hero-reanimated-measure--widthheight).

- **Start latency** runs from the handler's `performance.now()`, which is the
  native trace's clock (`CLOCK_UPTIME_RAW`); the recording is placed on that
  clock with the flights' run epochs (26 flights agree within ±2 ms). The
  flights' runs start in the handler and show in the next frame, which the
  recorder stamps 2–3 ms after it; a negative single run (−1.6 ms) is that
  ±2 ms error.
- **Touch-up → handler** is usually 1–6 ms, but up to 13–20 ms in every
  variant when the touch arrives while the main thread is busy (the trace
  logs the touch-up's hardware time and the time `sendEvent:` delivered it).
  That wait is the app's, not the transition's, so the start runs from the
  handler.
- **Old mount time** is the first frame moved more than 4 pt, now from the
  handler too. With the fast ease-out start it equals the start latency
  except for the flights (their first frame is only 2–3 ms into the run, so
  it sometimes moves the box less than 4 pt) and choreography (its first
  frame moves the photo but not yet its size).
- **Run start, fitted** maps every moving frame's top edge (position) and
  height (size) back through the curve to the time its run must have started
  (median over the frames between 10 and 90 % progress): the run's clock, not
  what the screen shows. In choreography and screen-transitions with
  `handoff` the teleported photo's size trails its position by 15–16 ms
  ([Why teleport starts later](#why-teleport-starts-later)).
- **Landed** is the first frame within 4 pt of the detail rect. Ease-out
  covers the last 4 pt slowly, so it comes about 100 ms before the run ends.
- No other opening showed a blank frame, and every run drew 60 frames per
  second (1 missed frame in 80 runs).

## Results: Android emulator

Release build (arm64-v8a, the same code), Pixel 10 Pro emulator (Android 17,
API 37) **with `-gpu host`**, 60 Hz; no load; the same flow, all 104
openings in one recording. Median (range) after **the tap marker's frame**,
in ms and in 60 Hz display frames; n = 10 for every cell.

| Variant                               | Teleport                | **Start latency** (marker frame → first changed frame) | Display frames | Touch-up → handler | Old mount time (marker → moved > 4 dp) | Run start, fitted: position / size | Landed              |
| ------------------------------------- | ----------------------- | ------------------------------------------------------ | -------------- | ------------------ | -------------------------------------- | ---------------------------------- | ------------------- |
| SmoothClipView flight                 | without                 | **16.1** (0.0–16.5)                                    | 1 (0–1)        | 0.9 (0.6–1.4)      | 16.1 (0.0–16.5)                        | 2.6 / 2.1                          | 400.7 (382.8–416.8) |
| SmoothClipView flight                 | with (added by hand)    | **0.0** (0.0–16.9)                                     | 0 (0–1)        | 0.9 (0.6–2.3)      | 0.0 (0.0–16.9)                         | −9.5 / −10.2                       | 383.2 (382.1–399.9) |
| Reanimated shared element transition  | none (no teleport mode) | **32.7** (15.8–49.3)                                   | 2 (1–3)        | 1.0 (0.8–1.4)      | 32.7 (15.8–49.3)                       | 17.6 / 16.9                        | 416.2 (398.8–432.6) |
| Reanimated `measure()` + width/height | without                 | **49.1** (32.3–50.0)                                   | 3 (2–3)        | 0.9 (0.6–1.4)      | 49.1 (32.3–50.0)                       | 16.9 / 16.2                        | 415.5 (398.8–418.7) |
| Reanimated `measure()` + width/height | with (added by hand)    | **48.9** (32.7–58.5)                                   | 3 (2–4)        | 1.4 (0.8–1.9)      | 48.9 (32.7–58.5)                       | 16.8 / 16.1                        | 415.7 (398.9–424.6) |
| react-native-screen-transitions       | without                 | **57.8** (33.3–115.1)                                  | 4 (2–7)        | 1.0 (0.7–1.5)      | 57.8 (33.3–115.1)                      | 42.4 / 41.5                        | 441.6 (416.5–498.3) |
| react-native-screen-transitions       | with (`handoff`)        | **67.0** (50.2–85.0)                                   | 4 (3–5)        | 1.2 (0.9–2.1)      | 67.0 (50.2–85.0)                       | 51.6 / 67.3                        | 466.4 (450.8–500.3) |
| react-native-screen-choreography      | with (required)         | **66.3** (49.3–83.0)                                   | 4 (3–5)        | 1.0 (0.7–1.4)      | 66.3 (49.3–83.0)                       | 43.7 / 59.6                        | 457.4 (433.3–482.3) |

- **From the marker's frame, not the handler.** The handler lights the tap
  marker, so its frame is the first frame after the handler. The screen
  recording shares no clock with the app, so the handler itself cannot be
  placed on it: Android numbers start up to one frame later than iOS's, and
  compare with them only that roughly. Medians of 10 frame-quantized runs can
  fall between frames (16.1 against 0.0 for the two flights is the same 0–1
  frame).
- **Touch-up → handler** comes from the kernel's touch events
  (`getevent -lt`; argent's taps go through the emulator's virtio touch
  device) and the handler's logged `performance.now()`, both on the uptime
  clock: 0.6–2.3 ms in every variant.
- Every opening was recorded at 60 frames per second (5 missed frames in 80
  runs), with no blank frame. The emulator's default GPU mode records about
  35: [Why the Android clips looked laggy](#why-the-android-clips-looked-laggy).

## What the numbers say

- **SmoothClipView starts in the tap's own frame**, with or without teleport:
  its run starts in the handler (fitted 0–2 ms) and the next frame shows it,
  3 ms after the handler on iOS and 0–1 frames after the marker on Android.
- **Reanimated SET** shows its run 35 ms after the handler (iOS) and 2 frames
  after the marker (Android). Its run starts at about 20 ms (fitted) and is
  seen in the frame after.
- **`measure()` + width/height** shows its run 51 ms after the handler (iOS),
  3 frames after the marker (Android), although its run's clock starts at
  about 17 ms: the first frame that shows the photo moved already has 15–19 %
  of the run behind it, about two frames, on both platforms. The run starts
  in the detail's mount effect, before its transparent modal is on screen.
  With teleport: 42 ms on iOS, 49 ms on Android, the same within the spread;
  with the photo at a fixed size the teleported photo no longer lags.
- **screen-choreography** shows its run 48 ms after the handler (iOS), 4
  frames after the marker (Android).
- **screen-transitions** is last on both: 85–89 ms (iOS), 58–67 ms from the
  marker (Android). On iOS, `handoff` no longer starts later than without
  (position fit 65.5 against 67.6 ms).

How far each run is in the first frame that shows it (median progress by the
box's height, iOS / Android): flights 0.016 / 0.04–0.06, SET 0.07 / 0.09,
`measure()` 0.16 / 0.19 (with teleport 0.09 / 0.19), screen-transitions
0.09 / 0.09, and 0 for the two whose teleported photo is a frame behind in
size (choreography, screen-transitions with `handoff`). At this curve one
frame is 0.10 of progress.

### Cross-check against the earlier run starts

The run starts fitted from the photo's position do not depend on the curve,
so the earlier recordings (ease-in-out, square corners, the earlier
`measure()` structure) can be compared with this one. iOS, median ms after
the touch-up:

| Variant                        | Earlier, position | Now, position | Now, start latency from the touch-up |
| ------------------------------ | ----------------- | ------------- | ------------------------------------ |
| SmoothClipView flight          | 2.2 (size)        | 3.0           | 5.4                                  |
| SmoothClipView flight + tp     | 3.3 (size)        | 8.6           | 9.3                                  |
| SET                            | 25.3 (size)       | 24.4          | 38.7                                 |
| `measure()`                    | 25.8              | 22.6          | 54.7                                 |
| `measure()` + teleport         | 24.0              | 25.4          | 47.5                                 |
| screen-transitions             | 70.8              | 70.2          | 91.0                                 |
| screen-transitions + `handoff` | 83.9              | 69.8          | 87.8                                 |
| choreography                   | 46.4              | 37.0          | 51.1                                 |

The run starts reproduce within about 3 ms for SET, both `measure()` variants and
screen-transitions. Two differ: screen-transitions with `handoff` no longer
starts its run a frame later than without, and choreography's run starts about
9 ms earlier than in the earlier session. Flight + teleport is later here
only because its touch-ups waited longer for the main thread (touch-up →
handler 6.7 against 2.0 ms); from the handler both flights start in it. The
direct start latency adds what the fits cannot see: the frame or two between
a run's clock and the first frame that shows it.

## Why the Android clips looked laggy

Every earlier Android opening showed 11–18 recorded frames (about 33 per
second). Three things caused it, the first by far the largest:

1. **The emulator rendered in software.** The AVD's `hw.gpu.mode=auto`
   resolves to lavapipe (Mesa's CPU Vulkan renderer) for this API 37 image
   on macOS: the running emulator's `hardware-qemu.ini` read
   `hw.gpu.mode = lavapipe`, qemu used about 930 % CPU, and the emulator's
   log explains the choice ("API level '37' requires GLES 3.1, please
   consider using 'software' rendering mode … Hardware rendering for OpenGL
   is deprecated on macOS"). With no recorder running, the app finished a
   frame every 25 ms during a run (38 fps; `dumpsys gfxinfo framestats`,
   26–31 ms of GPU work per frame), and the stock Settings app scrolled at
   25 fps (34 ms, 47 ms of GPU work): the whole emulator, not the app.
   Relaunched with `-gpu host`: Settings 16.6 ms (60 fps), the app 16.7 ms
   with and without the recorder, qemu 35–80 % CPU. Every variant renders
   correctly there (frame-by-frame checks, both curves).
2. **The recorder cost a few frames on lavapipe**, none on the host GPU. The
   app's median frame interval during flight runs: no recorder 25.0 ms;
   `screenrecord --size 640x1428 --bit-rate 8000000` (`record.sh`) 29.5 ms;
   426x952 at 4 Mbit/s 26.3 ms; the native size (which falls back to a
   distorted 720x1280) at 20 Mbit/s 27.6 ms. The recorder kept nearly every
   frame drawn (recorded gaps 28 ms against the app's 29.5).
3. **The video render dropped frames, on both platforms.** The recordings
   have a variable frame rate (a frame per screen change), so their average
   rate is low: 10.4 fps for the earlier Android recording, 22.8 for iOS.
   Matching every frame of the earlier video to its recording, the Android
   flight clip showed 12 of its run's 18 recorded frames and held some for 12
   output frames (100 ms of recording, one step of 1/10.4 s); the iOS flight
   clip showed 23 of 32, held up to 6 output frames. The new video plays
   120 fps constant-frame-rate excerpts (`clip-excerpts.swift`) and shows
   every recorded frame of a run for exactly 2 output frames at 0.5×.

No physical Android device was connected (`adb devices` listed only the
emulator).

## The variants

Every variant is a pair of expo-router routes: a grid (`index`) and a detail
(`[id]`). They share the photos, decoded by the same expo-image view with the
same props, the 20 pt corner radius on every tile and detail
(`GALLERY_RADIUS`), the tile and detail rects (`example/src/galleryBench/`), the
measured tile (row 2, column 2) and the tap: one UI-thread `Gesture.Tap` per
tile that lights the hero bench's tap marker and then calls the variant's open
function. The grid never moves; the detail's background fades in or appears
under the flying photo. Back closes every variant.

| Variant                                    | Routes                                           | Navigator                                                                                                                                                                  | The transition                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | Teleport                                                |
| ------------------------------------------ | ------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| SmoothClipView flight                      | `app/gallery-flight/`                            | native stack, `animation: 'fade'`                                                                                                                                          | Each tile is a window-sized `SmoothClipView` with `flight`, its photo laid out at the detail rect and cropped into the tile. The tap starts the run in its worklet (`clip.ui.animateTo`, window space), then pushes; the detail's `SmoothClipFlightTarget` takes over when it lands.                                                                                                                                                                                                                                                                                                  | not used                                                |
| SmoothClipView flight + teleport           | `app/gallery-flight-teleport/`                   | the same, inside teleport's `PortalProvider`                                                                                                                               | The same flight. react-native-teleport is added by hand (the library has no teleport mode): the detail renders no photo; its target holds a `PortalHost`, and the tile's live photo is teleported into it in the transaction that lands the flight (`ready` and the Portal's `hostName` change in one UI-thread props update), and back into its host when Back starts the run home.                                                                                                                                                                                                  | added by hand                                           |
| Reanimated shared element transition       | `app/gallery-set/`                               | native stack, `animation: 'fade'`                                                                                                                                          | An animated expo-image with `sharedTransitionTag` on both ends, `SharedTransition.duration(500)`, `SharedTransitionBoundary` per screen, as `hero-bench-set.tsx`.                                                                                                                                                                                                                                                                                                                                                                                                                     | none (no teleport mode)                                 |
| Reanimated `measure()` + width/height      | `app/gallery-measure/`                           | native stack; the detail is a `containedTransparentModal` with `animation: 'none'`                                                                                         | Plain Reanimated, no transition library (below): the tap worklet calls `measure()` on the tile's animated ref and keeps its window rect in a shared value; the detail starts `withTiming` (500 ms, `Easing.inOut(Easing.quad)`) in a mount effect and animates a rounded clip's left / top / width / height from that rect to the detail rect; the photo inside it is laid out once at the detail rect's size and only scaled by a transform (`galleryPhotoFrame`), so expo-image never re-fits it; its backdrop fades in with the same progress. Back runs it in reverse, then pops. | without: the detail renders its own copy                |
| Reanimated `measure()` + teleport          | `app/gallery-measure-teleport/`                  | the same, inside teleport's `PortalProvider`                                                                                                                               | The same run. The tile holds the photo that moves, laid out at the detail rect's size and scaled down to the tile, so its host never resizes. The detail renders no photo: its clip mounts empty over the tile, and the run's first frame moves the tile's live photo into it (the Portal's `hostName`, set from the UI thread); it moves back when the run home ends.                                                                                                                                                                                                                | added by hand                                           |
| react-native-screen-transitions            | `app/gallery-transitions/`                       | its Blank Stack (a JS navigator), nested in the root stack                                                                                                                 | `Transition.Boundary` (group `gallery`) on the tile and on the detail; the detail's interpolator styles its boundary with `bounds().styles({ method: 'size' })`, so the photo's frame moves and resizes from tile to detail; the backdrop fades in; the tile is hidden while its copy flies.                                                                                                                                                                                                                                                                                          | without: no boundary sets `handoff` or `escapeClipping` |
| react-native-screen-transitions + teleport | `app/gallery-transitions-teleport/`              | the same                                                                                                                                                                   | The same interpolator with `handoff` on both boundaries: the tile's live photo moves into the detail's empty boundary through react-native-teleport.                                                                                                                                                                                                                                                                                                                                                                                                                                  | with: `handoff`                                         |
| react-native-screen-choreography           | `app/gallery-choreography/index.tsx`, `[id].tsx` | the app's root native stack with `ChoreographyProvider` above it, each route in a `ChoreographyScreen`, the detail with `choreographyStackOptions` (its Expo Router guide) | `defineTransition` with one `bounds` shared element and `motion: { duration: 500 }`; the tile's photo is the owner, the detail an empty `Element.Target` with `fromSource`; `useChoreographyRouter().push` with the tile's group (what `Element.Pressable` passes), `back()` to close. The library moves the live photo through its overlay with react-native-teleport.                                                                                                                                                                                                               | required                                                |

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
- **Reanimated** shared element transitions have no teleport mode. A
  hand-wired attempt, made the same way as SmoothClipView's
  (`app/gallery-set-teleport/`, not measured), breaks the transition. Both
  ends are an `Animated.View` with the tile's tag; the detail's holds a
  `PortalHost`, and the tile's live photo is teleported into it in the
  commit that mounts the detail. SET then flies the detail's tagged view
  without the photo. The tile empties about 70 ms after the tap, nothing
  visible moves, and the photo appears at the detail only when the run has
  ended (about 617 ms; 38 blank frames per opening in a Debug recording). A
  broken transition is not a fast one, so there is no SET + teleport row.
- **Reanimated `measure()` + width/height** has no teleport mode either. At
  Kenneth's request its second row adds react-native-teleport by hand, as for
  SmoothClipView. Unlike SET's, it works: see below.

### The do-it-yourself hero: Reanimated `measure()` + width/height

The hero many apps write by hand, added after the first six variants
(`galleryMeasure.tsx`). Where it had to choose, it does what such code
usually does, and what the behaviour check showed:

- **A transparent modal without a native animation.** The grid must stay
  visible under the detail, and the photo is part of the detail screen, so
  a natively fading screen (the flights' and SET's `animation: 'fade'`)
  would fade the photo with it. It is the contained kind
  (`containedTransparentModal`, mounted in the stack's own view, as
  screen-transitions and choreography use); in a Debug check, a UIKit
  `transparentModal` left the tile empty for a frame.
- **The run starts on mount,** in a `useEffect`, from the JS thread.
- **The tile is not hidden.** The detail rect contains the tile, so the
  opaque copy covers it for the whole run. Hiding it from the effect that
  starts the run left it empty before the copy showed in 8 of 10 measured
  Release openings (and 2 of 3 warm-ups; 3–7 ms, twice about 18 ms): the
  hide reached the UI thread before the detail's mount.
- **A rounded clip around a photo of fixed size.** The clip animates left /
  top / width / height and keeps the gallery radius; the photo inside is laid
  out once at the detail rect's size and scaled by a transform to cover the
  clip. expo-image never re-fits it, and with teleport the host never resizes,
  so the teleported photo no longer trails its host by a frame (position and
  size fits agree: 18.8 / 18.1 ms). The plain tile shows a tile-sized photo;
  the teleport tile holds the detail-sized, scaled photo that moves.
- **With teleport, the photo moves in the run's first frame.** Teleporting
  it in the commit that mounts the detail (a Debug check) or from the mount
  effect (two Release recordings: 7 and 4 of 10 measured openings) left the
  tile empty for 3–7 ms, one recorded frame: the photo reached its new host
  before the detail's screen was shown. From the run's first frame (a
  UI-thread reaction to the progress) no opening showed a blank frame in the
  earlier structure. With the fixed-size photo frame, 2 of 10 measured iOS
  openings (none of the 3 warm-ups, none on Android) show the tile empty for
  one recorded frame, about 7 ms, just before the first moving frame: the
  hand-over still reaches the screen a commit before the detail's clip shows
  the photo there. It is not fixed here; the start latency skips blank
  frames. The photo moves back into its tile when the run home ends, with the
  container on the tile; no close showed a blank frame.

### Is screen-transitions set up right?

Kenneth asked whether it is odd that screen-transitions is faster without
teleport. Its setup matches the library's documentation (its repository,
`packages/docs` at v4.2.0):

- **`handoff` on both boundaries** of the pair, the tile's and the detail's.
  "Every matching boundary that should participate in that handoff should set
  `handoff`" ("Bounds Transitions" and the 3.9 changelog).
- **An empty destination.** "The destination defines the receiving bounds; it
  does not need to render a second copy of the live child." The docs' example
  wraps the payload in `Transition.Boundary.Target`; our boundaries have no
  target, so each boundary's own frame is measured and animated. The library
  supports that: a boundary without a target gets its handoff host at its
  root (`shouldRenderHandoffHost: handoffEnabled && !hasTarget` in
  `boundary-root.provider.tsx`).
- **Nothing else differs** between the two variants: the same Blank Stack,
  interpolator (`bounds().styles({ method: 'size' })`), 500 ms timing and tap.
- **No option skips the extra work.** The open waits until the destination
  boundary has measured itself and linked to its source
  (`useInitialDestinationMeasurement`); `handoff` adds no gate to that, and
  the library's own harness (`apps/harness`) has no teleport case.

So it is the library's handoff path, not a setup mistake: with `handoff`, its
run starts about 30 ms later on iOS (fitted run start 99.8 against 70.2 ms)
and about 35 ms later on the Android emulator (129.5 against 94.0 ms). The
docs call `handoff` experimental since 3.9.
[Why teleport starts later](#why-teleport-starts-later) splits those
milliseconds in two. One frame is react-native-teleport's: the handed-off
photo is sized a frame behind its resizing boundary. The other is the
library's: with `handoff`, its run starts a frame later after the detail
mounts.

Those numbers come from the earlier recordings (ease-in-out runs, timed from
the touch-up). In the start-latency recording the extra frame did not recur
on iOS: with `handoff` the run started as early as without (position fit 65.5
against 67.6 ms after the handler) and showed in the same frame (85.2 against
88.5 ms), though its photo's size still trails by a frame (size fit 81.4). On
the Android emulator `handoff` was still later: 67.0 against 57.8 ms from the
marker's frame (position fits 51.6 against 42.4).

### Why teleport starts later

_Measured on the earlier recordings: ease-in-out runs, square corners, and
the earlier `measure()` structure, which animated the photo's own container.
Since then the `measure()` hero keeps its photo at a fixed size, and its
teleport lag is gone (above)._

Kenneth asked why teleport makes the `measure()` hero and screen-transitions
slower, when it only moves a view that is already mounted and decoded. Both
are wired correctly. The extra milliseconds come from teleport sizing the
moved photo a frame late, plus, for screen-transitions, a frame its handoff
path waits. A decode is not one of them. The flight teleports only once it
has landed, when nothing resizes, so it pays none of this.

**1. The teleported photo is sized one frame behind its host.**
react-native-teleport 1.2.5 lays a teleported child out at its host's size
through the Portal's Fabric state, and that state follows the host's native
layout:

- iOS: the host's `layoutSubviews` →
  `PortalRegistry.notifyHostLayoutChanged` →
  `PortalView.updatePortalLayoutStateIfNeeded` → `_state->updateState`.
- Android: `PortalHostView.onLayout` → `PortalLayoutStateController` →
  `StateWrapper.updateState`.
- The update is asynchronous (React Native's default
  `EventQueue::UpdateMode::Asynchronous`): it is queued, applied on the JS
  thread, committed and mounted later. `PortalViewComponentDescriptor::adopt`
  then sizes the Portal, and the photo in it, from that state.
- Both slow variants resize their host every frame: the `measure()`
  container through left / top / width / height, the handoff boundary
  through `bounds().styles({ method: 'size' })` (width / height plus a
  translate). So in every frame the photo has the size its host had a frame
  earlier, pinned to the host's top-left corner.

The recorded frames show it. The top edge of the photo's box moves with its
host, whose position is set directly; the box's height is the photo's own.
Fitting the run start from each separately (the same fit as the fitted run
start column), from the committed recordings:

| Variant                        | Run start from the position       | Run start from the size (= fitted run start) | Size behind position, per opening |
| ------------------------------ | --------------------------------- | -------------------------------------------- | --------------------------------- |
| `measure()`, without teleport  | 25.8 (15.7–40.0)                  | 25.1 (15.0–39.3)                             | none (−1.1 to −0.5 ms)            |
| `measure()`, with teleport     | **24.0** (14.4–30.6)              | 39.7 (30.4–46.8)                             | **15.6–16.1 ms**, all 10          |
| screen-transitions, without    | 70.8 (45.1–96.7)                  | 70.2 (44.6–95.9)                             | none                              |
| screen-transitions, `handoff`  | **83.9** (69.9–100.5)             | 99.9 (86.3–116.3)                            | **15.7–15.9 ms**, all 10          |
| choreography (teleport always) | **46.4** (25.3–60.2)              | 62.4 (40.7–76.1)                             | **15.7–16.2 ms**, all 10          |
| flights (both), SET            | equal to the size fit within 1 ms | equal to the position fit within 1 ms        | none                              |

iOS, ms after the touch-up, median (range), n = 10. On the Android emulator,
after the marker: `measure()` 57.3 / 56.2 without teleport and **54.5** / 83.5
with it; screen-transitions 95.7 / 94.5 without and **104.4** / 133.1 with
`handoff`. There the size trails by one to three display frames (16–48 ms) in
every teleport opening and by nothing in the others.

So the `measure()` + teleport run starts when the run without teleport does;
only its photo's size is a frame behind, in every opening. Mount time counts
the photo's size, so it lands a frame later too: 91.9 against 72.4 ms.

**2. With a host of constant size, the lag goes away.** A local diagnostic
build (not committed, not a measured variant) moved and scaled the same
containers with a transform instead of width / height, and gave
screen-transitions `method: 'transform'`, so no host changed size. Both
builds are Release on the iPhone 18 Pro simulator: build A is the committed
code with marks on, build B is A with the transforms. Each recording ran one
flow (a flight cell, then the four variants; 3 warm-ups and 10 measured
openings each). Fitted run start (from the size), ms after the touch-up:

| Variant                       | A: width / height animated | B: transform, host size constant |
| ----------------------------- | -------------------------- | -------------------------------- |
| `measure()`, without teleport | 25.3 (20.3–34.9)           | 25.0 (12.7–38.1)                 |
| `measure()`, with teleport    | 39.8 (30.6–50.2)           | **25.5** (12.5–37.2)             |
| screen-transitions, without   | 67.2 (57.4–105.0)          | 75.1 (62.6–101.3)                |
| screen-transitions, `handoff` | 91.8 (70.0–105.1)          | 89.9 (65.5–105.9)                |

Build A reproduces the committed numbers. In build B no opening shows the
size behind the position (−1.2 to −0.3 ms in all 50), and the `measure()`
teleport penalty is gone. A frame remains for screen-transitions, the next
point. In B every `handoff` opening also showed one blank frame, so it is not
a usable setup; it only isolates the lag.

**3. screen-transitions' handoff also starts its run a frame later.** Phase
marks (`galleryMarks.ts`, below), median ms after the tap worklet, without →
with `handoff`:

| Build         | Detail renders | Its mount effect | The run's first animated frame |
| ------------- | -------------- | ---------------- | ------------------------------ |
| A (size)      | 18.6 → 22.6    | 23.2 → 27.9      | 68.0 → **82.2**                |
| B (transform) | 19.3 → 19.9    | 23.1 → 25.8      | 81.8 → **96.8**                |

The handoff boundaries render a few ms slower (a Portal and a PortalHost
each), and the first animated frame comes one frame, 14–15 ms, later. That
frame is spent between the detail's mount and the library's first frame
(its handoff path). We did not trace it further; that would need a patched
library. On iOS the two frames add up to the 30 ms in the table (99.8
against 70.2).

**4. Not the hand-over, and not the portals' mount.** In the `measure()`
variant (build A), the marks put the hand-over in the run's first frame
(27.0 ms after the tap), and that first frame as early as without teleport
(27.0 against 24.6 ms; ranges 16–43 and 16–49, both quantized to display
frames). Its detail even
renders and runs its mount effect a little sooner (8.3 and 11.4 ms against
9.6 and 13.4), since it has no photo of its own. The 12 Portals, the
`PortalProvider` and the detail's `PortalHost` cost nothing measurable. The
photo is in the moving container from the first moving frame. Handing it over
sooner could not help, since the lag recurs in every frame the host resizes.

**5. Teleport saves one decode in about thirty.** expo-image's iOS default
`cachePolicy` is `'disk'`, so SDWebImage queries and stores only its disk
cache: every load reads the JPEG and decodes it, off the main thread
(`onLoad` reported `cacheType: "disk"` for every load, never `"memory"`).
And expo-image's `ImageView` reloads whenever its bounds change size
(`bounds didSet → reload()`). So in both `measure()` variants the photo is
reloaded once per frame of the run: 31 (30–31) loads per opening without
teleport, 29.5 (28–30) with it. screen-transitions: 30 and 29. Teleport
saves only the detail copy's load at mount (29 ms after the tap, while the
tile still shows its own photo). With a constant-size host (build B) the
counts fall to 1 without teleport and 0 with it.

**So it is inherent** to react-native-teleport when the host's size
animates: the teleported content is laid out through Fabric state, one
commit behind its host. Our hand-over timing and the portals' mount add
nothing. A teleport hero that keeps its host's size constant and moves it
with a transform avoids the lag. It scales the photo instead of re-fitting it,
though, so it is a different transition from the one measured here. The
`measure()` hero now does that (a rounded clip around a fixed-size, scaled
photo), and its lag is gone. The
numbers above stay as measured.

**How it was measured.** The position / size split re-analyses the committed
recordings with `analyze-frames.swift` and fits each moving frame's top edge
and height separately through the variant's curve. It uses only the frames
between 5 and 95 % of the run, so its medians can differ from the table's by
a few ms (up to 4 ms on Android, where frames are sparse); per run, the
re-analysis reproduces the committed values exactly. The marks come from `example/src/galleryBench/galleryMarks.ts`, off
by default (`GALLERY_MARKS`). With it on, every opening logs its phases and
expo-image loads at the info level, readable with
`xcrun simctl spawn <udid> log show --info`. The transform builds are not
committed.

## Method

The hero bench's tooling (`docs/hero-bench.md`), extended for a grid and for
start latency:

- **The switch.** The gallery hub's **Start-latency bench** button
  (`example/src/galleryBench/galleryStartBench.ts`, off by default) gives
  every variant choreography's 500 ms `Easing.out(Easing.cubic)`: the
  flights `ClipEasings.easeOutCubic` (exact), SET
  `SharedTransition.duration(500).easing(…)`, `measure()` and
  screen-transitions (`transitionSpec`) the Reanimated easing. Choreography
  cannot take another curve (its timed run is hardcoded in
  `core/ProgressOwnership.ts`), so the others copy it. The switch also makes
  the tap handler log its `performance.now()` (`[gallery-tap]`), taken first
  thing in the handler and logged after the variant's own work.
- **Flows.** `.argent/flows/gallery-bench/bench.yaml`: the switch on, then per
  variant 3 warm-up open/close cycles (kept, marked) and 10 measured ones, all
  eight variants in one recording, the flights first. `check.yaml` is one
  cycle of each variant with the switch off (the usual curves),
  `check-start-bench.yaml` the same with it on; both were recorded and
  checked frame by frame on both platforms before measuring.
  `frames-probe.yaml` is three flight cycles, for frame-rate checks.
- **Frames.** `record.sh` records the screen; `analyze-frames.swift` finds
  the photo's bounding box in every frame, ignoring the other 11 tiles
  (`HERO_MASK`). The 20 pt corners leave that box unchanged (each edge's
  midpoint is photo): every opening rested at exactly the tile's box on iOS
  ([140, 206, 122, 122]) and within 1 dp of it on Android, and every variant
  settled at the detail's.
- **The first changed frame** (`summarize.mjs`): the first frame from the
  marker's frame on that is not blank and whose box has any edge more than
  `HERO_CHANGE_TOL` from the frame before the marker (1 pt on iOS, 2 dp on
  Android, where the encoder moves a still tile's edges by up to 2 dp). The
  earlier 4 pt first motion stays (`HERO_NEAR_TOL`), and so does the curve
  fit, now from the box's height (size) and its top edge (position).
- **iOS clock.** A build with `SMOOTH_CLIP_HERO_TRACE=1` logs the hardware
  time of every touch-up and every flight's run epoch; `trace.sh` streams
  them with the app's info-level `[gallery-tap]` lines. `timing.mjs` places
  the recording on that clock with the flights, then times every opening
  from its handler (the last one before its marker frame, allowing 10 ms:
  the recorder stamps that frame about 2 ms after the handler, ±2 ms) and
  from the touch-up before it.
- **Android clock.** `record.sh` also saves `getevent -lt` and the app's
  `logcat`; `input-clock.mjs` pairs each handler with the touch-up before it.
  The recording's timestamps start at 0 and share no clock with either, so
  frames are timed from the marker's frame.
- **The emulator** runs with `-gpu host`; its default (`auto`) renders this
  API 37 image in software at about 35 fps.
- **Data and video.** `gallery-json.mjs` writes the JSON from both
  recordings. The video comes from app-showcase's
  `showcases/gallery-mount-time/make-showcase.mjs`, which picks the run
  nearest each median, writes `make-excerpts.sh` to cut each clip into a
  120 fps constant-frame-rate excerpt (`clip-excerpts.swift`), and
  `showcase.json`; then `npm run render -- gallery-mount-time`.

```sh
UDID=E99A3C2E-3463-439A-8088-A108DB9DB535
CELLS=$(sed -n 's/^# Cells: //p' .argent/flows/gallery-bench/bench.yaml)
HERO_LAYOUT=$IOS_LAYOUT example/scripts/hero-bench/trace.sh $UDID \
  .argent/flows/gallery-bench/bench.yaml /tmp/start-ios "$CELLS"
HERO_LAYOUT=$ANDROID_LAYOUT example/scripts/hero-bench/record.sh emulator-5554 \
  .argent/flows/gallery-bench/bench.yaml /tmp/start-android "$CELLS"
node example/scripts/hero-bench/input-clock.mjs /tmp/start-android "$CELLS"
node example/scripts/hero-bench/gallery-json.mjs /tmp/start-ios /tmp/start-android \
  "$CELLS" docs/gallery-mount-time.json <meta.json>
```

`IOS_LAYOUT` and `ANDROID_LAYOUT` are the `layout:` lines a Debug build
prints (`METRO_PORT=<port> record.sh … check.yaml`), as for the hero bench;
the layout is the same as before the corners changed. Frames of one opening
can be checked with `contact-sheet.swift`.

## Versions

| Package                                         | Version                                            |                                                                                          |
| ----------------------------------------------- | -------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| react-native-smooth-clip-view                   | this branch (0.6.0 flights + the gallery bench)    | built from source, with `SMOOTH_CLIP_HERO_TRACE=1` on iOS                                |
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

Xcode 27.2 (27B52), iOS 27.0 simulator runtime (24A434); Android emulator
37.2.12.0 with `-gpu host`, Pixel_10_Pro AVD (API 37, CP41.260831.007). No
package is patched (the repo's existing `@legendapp/list` patch is
unrelated).

## Caveats

- **Simulator and emulator only.** The numbers compare the variants with each
  other on one Mac. They are not device numbers.
- **Frame times are the recorders'.** The simulator's recorder stamps a frame
  when it is drawn, about 2 ms after the handler for the frame after the tap,
  not at a display vsync; Android's frames are timed from the marker's frame.
  Both apply equally to every variant. Single runs are quantized to the
  16.7 ms frame.
- **Android starts a frame later than iOS.** It runs from the first frame
  after the handler, so its numbers include up to one frame less than iOS's
  would. Compare the platforms only roughly.
- **The curve.** Every variant runs choreography's 500 ms cubic ease-out
  for the measurement, not its usual curve. The start latency does not depend
  on it beyond the detection threshold: a run that has moved the photo less
  than 1 pt by its first frame (under about 1 ms into it at this curve) is
  counted from the next frame. The video shows the same ease-out runs.
- **The emulator's GPU.** `-gpu host` is the emulator's hardware OpenGL path,
  which it calls deprecated on macOS for API 37; every variant rendered
  correctly on it (frame-by-frame checks). The AVD's own setting is still
  `auto`, so a cold launch without the flag renders in software again.
- **`measure()` + teleport blank frame:** 2 of 10 measured iOS openings
  (about 7 ms each), above.
- **Navigators.** Each library runs as its docs recommend, so the navigators
  differ. The flights and SET push a native-stack route that fades in
  (`animation: 'fade'`), nested in the root stack. screen-transitions needs
  its own JavaScript navigator (Blank Stack) for bounds transitions; its
  detail fades in on the Blank Stack's backdrop. Choreography presents its
  detail as a contained transparent modal without native animation and fades
  it in itself; `measure()` uses the same kind of modal. The grid never moves
  in any variant.
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
- **Corners, fixed after these recordings.** Two things squared some
  corners in the recordings and the video; neither moves the analysed box
  (its edges' midpoints are photo), so no number changes.
  - On Android, `SmoothClipFlightTarget` ignored its `borderRadius` and
    `overflow` (a library bug: its codegen view manager dropped them), so the
    flights' photos lost their corners in the frame they landed. Fixed in
    the library (`ViewStyleDelegate.kt`).
  - react-native-teleport sizes a teleported photo from its host's previous
    frame, so while the host grows the photo is smaller than its rounded
    clip, pinned to its top-left corner: mid-run only that corner was rounded
    in screen-transitions with `handoff` and in choreography, on both
    platforms. Their photos now carry their own 20 pt corners
    (`galleryStyles.roundedFill`; screen-transitions' photos without
    `handoff` too, so the pair stays alike).
- **Flight + teleport close glitch.** Its opening is clean, but its closes
  show the photo missing for a frame before the run home lifts it (one
  recorded frame on iOS, two at 60 fps on Android): the photo is teleported
  back into its host one commit before the lift. Closes are not measured; it
  is a limit of this hand-made integration, not of either library.
- **Masked analysis.** The other 11 photos are ignored; the measured photo is
  tracked through the dark gutters and the margins. It is exact to a point
  for a rect that grows around its tile, which every variant does here.

## Data

`docs/gallery-mount-time.json`: the metric, the curve, both devices, builds
and recordings (`ios`, `android`), the versions, the iOS calibration
(`calibration`), and per platform every variant (`variants`, median / min /
max / n) and every run (`runs`, warm-ups marked `warmUp: true`). Every run and
variant carries `platform`.

- iOS runs: `startLatencyMs` (handler → first changed frame),
  `touchUpToHandlerMs`, `handlerToMarkerMs`, `handlerToFirstMotionMs` and
  `touchUpToFirstMotionMs` (the old 4 pt mount time), `touchUpToFirstChangeMs`,
  `handlerToFittedRunStartMs` (`position`, `size`), `handlerToLandedMs`, and
  the recording times of the touch-up, the handler and the marker's frame.
- Android runs: `markerToFirstChangeMs` and `markerToFirstChangeFrames` (60 Hz
  display frames), `touchUpToHandlerMs`, `markerToFirstMotionMs`,
  `markerToFittedRunStartMs`, `markerToLandedMs`, and the recording time of
  the marker's frame.
- Both: `firstChange` (the changed frame's largest edge change in pt or dp,
  its progress by height and by top edge, and recorded frames after the
  marker's), `framesShown`, `missedFrames`, `blankFrames`.

The recordings are in app-showcase's `showcases/gallery-mount-time/`
(untracked): `gallery-start-latency-ios.mp4` and
`gallery-start-latency-android.mp4`.
