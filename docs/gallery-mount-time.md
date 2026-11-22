# Gallery mount time: eight route transitions on one photo grid

Measured 2026-11-22. One photo gallery (12 photos, 3 columns) in the example
app, opened to a detail route by eight transition variants. **Mount time** is
the time from the hardware touch-up on a tile to the first recorded frame in
which the photo has moved more than 4 pt from its tile: the "Mount time"
column of `docs/hero-flight-results.md`, measured the same way. On iOS it runs
from the touch-up; on the Android emulator, which has no native trace, from
the tap marker ([Results: Android emulator](#results-android-emulator)).

## Results: iOS

Release build, iPhone 18 Pro simulator (iOS 27.0, 60 Hz), no load; 10 measured
openings of the same tile per variant after 3 warm-ups, in one recording (the
two `measure()` rows in a second one, ²). Median (range) in ms after the
hardware touch-up; n = 10 for every cell.

| Variant                               | Teleport                | Version                               | **Mount time** (touch-up → first motion > 4 pt) | n   | Cross-check: tap marker → first motion | Fitted run start  | Landed              |
| ------------------------------------- | ----------------------- | ------------------------------------- | ----------------------------------------------- | --- | -------------------------------------- | ----------------- | ------------------- |
| SmoothClipView flight                 | without                 | 0.5.4 + flights (`f0db256`)           | **54.3** (38.5–69.9)                            | 10  | 49.1 (31.7–53.3)                       | 2.2 (0.4–15.7)    | 479.9 (474.3–486.5) |
| SmoothClipView flight                 | with (added by hand)    | the same, react-native-teleport 1.2.5 | **50.6** (38.6–67.0)                            | 10  | 45.0 (31.7–51.7)                       | 3.3 (−1.0–12.2)   | 477.8 (474.0–485.3) |
| Reanimated shared element transition  | none (no teleport mode) | react-native-reanimated 4.8.0         | **69.8** (58.0–83.8)                            | 10  | 63.4 (51.7–73.3)                       | 25.3 (16.5–36.5)  | 501.1 (492.3–503.8) |
| Reanimated `measure()` + width/height | without                 | react-native-reanimated 4.8.0         | **72.4** (64.4–86.6) ²                          | 10  | 64.2 (50.0–68.3)                       | 25.0 (15.0–39.3)  | 495.6 (484.4–507.4) |
| Reanimated `measure()` + width/height | with (added by hand)    | the same, react-native-teleport 1.2.5 | **91.9** (80.6–98.5) ²                          | 10  | 82.5 (78.3–85.0)                       | 39.7 (30.3–47.0)  | 510.3 (499.3–518.5) |
| react-native-screen-transitions       | without                 | 4.2.0                                 | **118.5** (92.9–145.8)                          | 10  | 106.7 (88.3–131.7)                     | 70.2 (44.6–95.8)  | 540.1 (514.6–564.1) |
| react-native-screen-transitions       | with (`handoff`)        | 4.2.0, react-native-teleport 1.2.5    | **148.2** (134.0–164.5)                         | 10  | 133.3 (116.7–151.7)                    | 99.8 (86.3–116.3) | 569.0 (555.6–584.5) |
| react-native-screen-choreography      | with (required)         | 0.9.0, react-native-teleport 1.2.5    | **59.8** (36.5–70.1) ¹                          | 10  | 46.7 (33.3–50.0)                       | 62.2 (40.5–76.0)  | 457.3 (439.9–473.4) |

¹ **Read choreography's mount time with its curve.** Its only timing run is
`Easing.out(Easing.cubic)`; every other variant runs ease-in-out-quad. An
ease-out run moves the photo about 37 pt in its first frame, where
ease-in-out-quad moves it under 1 pt and needs about 36 ms to pass 4 pt. So
choreography's first visible motion is the first frame of its run, while its
run itself starts later than every variant but screen-transitions: 62 ms
after the touch-up (fitted), against 2–3 ms for the flights and 25 ms for
SET. With the bench's curve its mount time would be about 62 + 36 ≈ 98 ms;
that is an estimate, not a measurement. (The 62 ms is fitted from the
photo's size, which trails choreography's teleported photo by a frame; by its
position the run starts at 46 ms. See
[Why teleport starts later](#why-teleport-starts-later).)

² **Measured later, in a second recording** (`bench-measure.yaml`): a flight
cell, which calibrates the recording's clock, then the two `measure()`
variants. That flight cell's mount time, 53.3 (38.4–62.1) ms, matches the
first recording's 54.3, so the two sessions compare. No opening of either
`measure()` variant showed a blank frame.

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
  the curve (the rect is interpolated linearly in progress); for the flights
  it agrees with the run epochs in the trace. In the three variants that
  teleport the photo at the start of the run (`measure()` + teleport,
  screen-transitions with `handoff`, choreography) the height follows it one
  frame late, so their fitted run start is a frame after the run's own start
  ([Why teleport starts later](#why-teleport-starts-later)).
- **Landed** is the first frame at the detail rect. Every run lasts 500 ms.
- No measured opening showed a blank frame or missed a display frame.

Simulator numbers compare the variants with each other on one machine. They
are not device numbers.

## Results: Android emulator

Release build (arm64-v8a, the same code), Pixel 10 Pro emulator (Android 17,
API 37), no load; 10 measured openings of the same tile per variant after 3
warm-ups, in one recording (the `measure()` rows in a second one, ²). Median
(range) in ms **after the tap marker**,
not the touch-up: Android has no native trace, so these numbers have no
touch-up time and no cross-check. n = 10 for every cell.

| Variant                               | Teleport                | Version                               | **Mount time** (tap marker → first motion > 4 dp) | n   | Fitted run start (after the marker) | Landed (after the marker) |
| ------------------------------------- | ----------------------- | ------------------------------------- | ------------------------------------------------- | --- | ----------------------------------- | ------------------------- |
| SmoothClipView flight                 | without                 | 0.5.4 + flights (`f0db256`)           | **84.5** (55.1–95.2)                              | 10  | 45.2 (23.5–75.0)                    | 545.2 (518.2–562.8)       |
| SmoothClipView flight                 | with (added by hand)    | the same, react-native-teleport 1.2.5 | **80.8** (47.9–101.5)                             | 10  | 44.2 (14.2–59.1)                    | 538.4 (504.4–556.1)       |
| Reanimated shared element transition  | none (no teleport mode) | react-native-reanimated 4.8.0         | **123.4** (111.0–147.6)                           | 10  | 62.1 (44.7–86.5)                    | 530.5 (513.2–577.8)       |
| Reanimated `measure()` + width/height | without                 | react-native-reanimated 4.8.0         | **100.3** (81.1–125.2) ²                          | 10  | 55.4 (35.3–66.7)                    | 534.2 (493.7–553.1)       |
| Reanimated `measure()` + width/height | with (added by hand)    | the same, react-native-teleport 1.2.5 | **125.7** (105.7–134.5) ²                         | 10  | 83.9 (72.1–94.5)                    | 555.8 (525.3–568.9)       |
| react-native-screen-transitions       | without                 | 4.2.0                                 | **149.1** (135.9–182.2)                           | 10  | 94.0 (72.0–128.4)                   | 585.5 (544.3–617.5)       |
| react-native-screen-transitions       | with (`handoff`)        | 4.2.0, react-native-teleport 1.2.5    | **183.8** (167.1–222.8)                           | 10  | 129.5 (118.3–181.9)                 | 601.7 (567.9–653.5)       |
| react-native-screen-choreography      | with (required)         | 0.9.0, react-native-teleport 1.2.5    | **149.6** (99.3–212.3) ¹                          | 10  | 143.4 (115.0–169.6)                 | 557.4 (527.8–598.8)       |

¹ Choreography runs cubic ease-out here too (see the iOS note): its first
motion is the first frame of its run.

² A second recording here too, with a flight cell for reference. That cell
gave 73.8 (44.4–91.5) ms against 84.5 in the first recording: emulator
sessions differ by about 10 ms, so compare these two rows with the others
only within that margin. Neither showed a blank frame.

- **Mount time** is the tap marker → first recorded frame in which the photo
  has moved more than 4 dp from its tile. The marker is lit in the touch-up's
  UI-thread turn, so the touch-up itself comes a little earlier (6–13 ms on
  iOS); Android cannot say how much.
- **The emulator's frame rate is not trustworthy.** Its display mode is
  60 Hz, but it showed 11–18 frames per 500 ms run (about 33 per second;
  every run "misses" 10–17 display frames). Android numbers compare the
  variants with each other on the emulator only: not with iOS, and not with
  a device.
- No opening showed a blank frame. The behaviour check (`check.yaml` and
  `check-measure.yaml`, one recorded opening per variant, frame by frame)
  found every variant landing
  without a blank frame, a double image or a jump of the photo. One
  difference from iOS: **choreography's grid disappears in one recorded
  frame** at the start of its run, where iOS fades it out over about three
  frames. The photo itself is clean.
- The order matches iOS except SET, which is slower than both flights by
  about 40 ms here (on iOS by 15–19 ms), and choreography, whose run starts
  last on Android (143 ms after the marker; on iOS it starts before both
  screen-transitions runs). screen-transitions with `handoff` again starts
  its run about 35 ms later than without (129.5 against 94.0); most of that
  is teleport's size lag ([Why teleport starts later](#why-teleport-starts-later)).

## The variants

Every variant is a pair of expo-router routes: a grid (`index`) and a detail
(`[id]`). They share the photos, decoded by the same expo-image view with the
same props, the tile and detail rects (`example/src/galleryBench/`), the
measured tile (row 2, column 2) and the tap: one UI-thread `Gesture.Tap` per
tile that lights the hero bench's tap marker and then calls the variant's open
function. The grid never moves; the detail's background fades in or appears
under the flying photo. Back closes every variant.

| Variant                                    | Routes                                           | Navigator                                                                                                                                                                  | The transition                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | Teleport                                                |
| ------------------------------------------ | ------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| SmoothClipView flight                      | `app/gallery-flight/`                            | native stack, `animation: 'fade'`                                                                                                                                          | Each tile is a window-sized `SmoothClipView` with `flight`, its photo laid out at the detail rect and cropped into the tile. The tap starts the run in its worklet (`clip.ui.animateTo`, window space), then pushes; the detail's `SmoothClipFlightTarget` takes over when it lands.                                                                                                                                                                                               | not used                                                |
| SmoothClipView flight + teleport           | `app/gallery-flight-teleport/`                   | the same, inside teleport's `PortalProvider`                                                                                                                               | The same flight. react-native-teleport is added by hand (the library has no teleport mode): the detail renders no photo; its target holds a `PortalHost`, and the tile's live photo is teleported into it in the transaction that lands the flight (`ready` and the Portal's `hostName` change in one UI-thread props update), and back into its host when Back starts the run home.                                                                                               | added by hand                                           |
| Reanimated shared element transition       | `app/gallery-set/`                               | native stack, `animation: 'fade'`                                                                                                                                          | An animated expo-image with `sharedTransitionTag` on both ends, `SharedTransition.duration(500)`, `SharedTransitionBoundary` per screen, as `hero-bench-set.tsx`.                                                                                                                                                                                                                                                                                                                  | none (no teleport mode)                                 |
| Reanimated `measure()` + width/height      | `app/gallery-measure/`                           | native stack; the detail is a `containedTransparentModal` with `animation: 'none'`                                                                                         | Plain Reanimated, no transition library (below): the tap worklet calls `measure()` on the tile's animated ref and keeps its window rect in a shared value; the detail starts `withTiming` (500 ms, `Easing.inOut(Easing.quad)`) in a mount effect and animates its photo container's left / top / width / height from that rect to the detail rect, so expo-image re-fits the photo every frame; its backdrop fades in with the same progress. Back runs it in reverse, then pops. | without: the detail renders its own copy                |
| Reanimated `measure()` + teleport          | `app/gallery-measure-teleport/`                  | the same, inside teleport's `PortalProvider`                                                                                                                               | The same run. The detail renders no photo: its container mounts empty over the tile, and the run's first frame moves the tile's live photo into it (the Portal's `hostName`, set from the UI thread); it moves back when the run home ends.                                                                                                                                                                                                                                        | added by hand                                           |
| react-native-screen-transitions            | `app/gallery-transitions/`                       | its Blank Stack (a JS navigator), nested in the root stack                                                                                                                 | `Transition.Boundary` (group `gallery`) on the tile and on the detail; the detail's interpolator styles its boundary with `bounds().styles({ method: 'size' })`, so the photo's frame moves and resizes from tile to detail; the backdrop fades in; the tile is hidden while its copy flies.                                                                                                                                                                                       | without: no boundary sets `handoff` or `escapeClipping` |
| react-native-screen-transitions + teleport | `app/gallery-transitions-teleport/`              | the same                                                                                                                                                                   | The same interpolator with `handoff` on both boundaries: the tile's live photo moves into the detail's empty boundary through react-native-teleport.                                                                                                                                                                                                                                                                                                                               | with: `handoff`                                         |
| react-native-screen-choreography           | `app/gallery-choreography/index.tsx`, `[id].tsx` | the app's root native stack with `ChoreographyProvider` above it, each route in a `ChoreographyScreen`, the detail with `choreographyStackOptions` (its Expo Router guide) | `defineTransition` with one `bounds` shared element and `motion: { duration: 500 }`; the tile's photo is the owner, the detail an empty `Element.Target` with `fromSource`; `useChoreographyRouter().push` with the tile's group (what `Element.Pressable` passes), `back()` to close. The library moves the live photo through its overlay with react-native-teleport.                                                                                                            | required                                                |

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
- **With teleport, the photo moves in the run's first frame.** Teleporting
  it in the commit that mounts the detail (a Debug check) or from the mount
  effect (two Release recordings: 7 and 4 of 10 measured openings) left the
  tile empty for 3–7 ms, one recorded frame: the photo reached its new host
  before the detail's screen was shown. From the run's first frame (a
  UI-thread reaction to the progress) no opening showed a blank frame. The
  photo moves back into its tile when the run home ends, with the container
  on the tile; no close showed a blank frame either.

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

### Why teleport starts later

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

The hero bench's tooling (`docs/hero-bench.md`), extended for a grid:

- **Flows.** `.argent/flows/gallery-bench/bench.yaml`: per variant, 3 warm-up
  open/close cycles (discarded), then 10 measured ones, all on the same tile,
  in one recording, the flights first. `check.yaml` is one cycle of each
  variant for the behaviour check. The two `measure()` variants came later:
  `check-measure.yaml` and `bench-measure.yaml` (a flight cell first, which
  calibrates the iOS recording's clock and checks the session against the
  first recording; its numbers are not results).
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
- **Android.** The same flows and cells in a Release build on the
  Pixel_10_Pro emulator (`emulator-5554`, API 37, emulator 37.2.12.0).
  `record.sh` records an adb device with `screenrecord --size 640x1428`
  (half the native 1280 × 2856; at full size the encoder falls back to a
  distorted 720 × 1280) and runs the flow with `--platform android`; the
  layout comes from a Debug build through Metro, as on iOS (the window is
  426.7 × 952 dp with a 52 dp status bar, so its rects differ). At 1.5 px per
  dp the encoder bleeds a photo's edge into the 6 dp gutters, so each masked
  tile grows by 1 dp on Android (`HERO_MASK_PAD`). There is no native trace:
  times run from the tap marker, and `gallery-json.mjs --android` merges the
  runs into the JSON.

```sh
UDID=E99A3C2E-3463-439A-8088-A108DB9DB535
CELLS=flight-warm/0:3,flight/0:10,flight-tp-warm/0:3,flight-tp/0:10,set-warm/0:3,set/0:10,st-warm/0:3,st/0:10,st-tp-warm/0:3,st-tp/0:10,choreo-warm/0:3:easeOutCubic,choreo/0:10:easeOutCubic
HERO_LAYOUT=$LAYOUT example/scripts/hero-bench/trace.sh $UDID .argent/flows/gallery-bench/bench.yaml /tmp/gallery $CELLS
```

`LAYOUT` is the `layout:` line a Debug build prints (`METRO_PORT=<port>`
`record.sh … check.yaml`), as for the hero bench. On Android:

````sh
HERO_LAYOUT=$ANDROID_LAYOUT example/scripts/hero-bench/record.sh emulator-5554 \
  .argent/flows/gallery-bench/bench.yaml /tmp/gallery-android $CELLS
node example/scripts/hero-bench/gallery-json.mjs --android /tmp/gallery-android \
  $CELLS docs/gallery-mount-time.json <meta.json>
```

The `measure()` recordings, on each platform:

```sh
CELLS=flight-warm/0:3,flight/0:10,measure-warm/0:3,measure/0:10,measure-tp-warm/0:3,measure-tp/0:10
HERO_LAYOUT=$LAYOUT example/scripts/hero-bench/trace.sh $UDID .argent/flows/gallery-bench/bench-measure.yaml /tmp/gallery-measure $CELLS
node example/scripts/hero-bench/gallery-json.mjs --add ios /tmp/gallery-measure $CELLS \
  docs/gallery-mount-time.json gallery-mount-time-measure.mp4 measure,measure-tp
HERO_LAYOUT=$ANDROID_LAYOUT example/scripts/hero-bench/record.sh emulator-5554 \
  .argent/flows/gallery-bench/bench-measure.yaml /tmp/gallery-measure-android $CELLS
node example/scripts/hero-bench/gallery-json.mjs --add android /tmp/gallery-measure-android $CELLS \
  docs/gallery-mount-time.json gallery-mount-time-android-measure.mp4 measure,measure-tp
``` Frames of one opening can be
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
- **Android is the emulator, timed from the marker.** No native trace, so no
  touch-up time; the emulator draws about 33 frames per second on a 60 Hz
  mode, so a first motion is quantized to about 30 ms and the numbers compare
  the variants with each other on the emulator only. The first six variants'
  78 Android openings are in one 6-minute recording.
- **Two recordings per platform.** The `measure()` variants were measured
  in a second session. On iOS its flight cell matches the first (53.3
  against 54.3 ms); on the emulator it is about 10 ms faster (73.8 against
  84.5 ms), so the Android `measure()` rows compare with the others only
  within that margin.

## Data

`docs/gallery-mount-time.json`: the versions, the calibration, and every run
(warm-ups marked), with the recording times of its touch-up and marker frame.
Every run and variant carries `platform`. The Android ones (`"android"`)
have marker-based times only (`markerToFirstMotionMs`,
`markerToFittedRunStartMs`, `markerToLandedMs`, and the recording time of the
marker frame); the top-level `android` entry describes their device, build
and recording. The `measure()` runs come from a second recording per
platform: each names its `recording.file`, and `recordings` lists those
recordings with the iOS one's calibration and the medians of their flight
cells (a reference, not results).
````
