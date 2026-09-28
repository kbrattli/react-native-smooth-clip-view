# Changelog

## Unreleased

- `useSmoothClipController` validates and canonicalizes its initial
  presentation on the first render only, the render that seeds the host. A
  caller that rebuilds the object every render (a presentation derived from a
  layout width) no longer pays a canonicalization per render; a later invalid
  value is ignored rather than thrown, as it was already never applied.
- Test: the full-turn rotation interruption XCTest reads a 20 s run begun 8 s
  in the past instead of a 2 s run begun 0.6 s ago, so a loaded CI machine can
  no longer overrun its window (it read 4.6 turns, past the `< 4 pi` bound).

## [0.5.1](https://github.com/kbrattli/react-native-smooth-clip-view/releases/tag/v0.5.1) — 2026-09-28

- **Fix: iOS baked shadows were invisible.** `shadowRendering="baked"` baked
  its tile by rendering a shadowPath-only layer through `renderInContext:`,
  which draws a layer's shadow only where the layer has content of its own,
  so every tile was fully transparent and a baked host drew no shadow at all.
  The tile is now drawn as a Core Graphics shadow inside a UIKit image
  renderer, whose base transform also scales the blur with the tile's scale
  (a hand-scaled bitmap context left the shadow in pixel space). A Core
  Graphics shadow of `blur` has the same sigma as Core Animation's
  `shadowRadius = blur / 2`, so the tile matches the blur path's shadow
  sample for sample; the iOS and Android suites now pin the tile's alpha
  profile. Android tiles were unaffected.

## [0.5.0](https://github.com/kbrattli/react-native-smooth-clip-view/releases/tag/v0.5.0) — 2026-09-28

- **Backdrop channel.** A presentation gains `backdrop: { translateX,
  translateY }`, and the new `SmoothClipBackdropView` (`controller={clip}`)
  is translated by it: every `setFrame` writes the channel in the same native
  call as the clip, and every run animates it on the clip's own epoch (a
  translation group on the shared Core Animation `beginTime` on iOS, the same
  Choreographer advance on Android). Content that must stay locked to the
  aperture no longer needs a Reanimated mapper, which can land a frame after
  the clip. The native packet grows by two values (stride 23 → 25) and the
  host takes `initialBackdropTranslateX/Y`, so a native rebuild is required;
  a JavaScript-only update cannot upgrade an older native build.
- iOS anchors a native run to the frame stamp JS passes (Reanimated's
  `__frameTimestamp`, the display link's target vsync) as the shared Core
  Animation `beginTime`, the way the Android frame loop already did. A run and
  a `withTiming` begun in the same UI frame now trace one epoch; before, the
  run began at its install time and led the Reanimated model by the rest of
  that frame (about 14 ms at 60 Hz). Animation groups carry backwards fill so a
  stamp up to one frame ahead of the commit shows the run's first frame, not
  the target. JS now stamps runs on every platform.
- `shadowRendering="baked"` on `SmoothClipView` renders the box shadow from one
  pre-blurred tile per 4 pt corner-radius step that the compositor stretches
  (`contentsCenter` on iOS, nine bitmap pieces on Android), so an animated or
  dragged aperture costs no blur per frame. iOS bakes the tile through Core
  Animation's own shadow path so it matches a `shadowPath` layer; Android
  bakes it with the same `BlurMaskFilter` as the blur path. Runs animate the
  tile layer's frame and opacity and swap tiles in steps where the radius,
  blur or colour changes. Uniform radii only, and a shape at least
  2 × (1.5 × blur + radius) on a side; unequal radii or a smaller shape keep
  the blur path. Default stays `"blur"`.
- Android builds a uniform circular corner with `addRoundRect` in the shared
  path builder, so the shadow path (not only the clip) stays an rrect the
  renderer can clip and blur analytically. Paths are `rewind()` instead of
  `reset()` between frames, keeping their storage.
- Baked tiles no longer bake inside the frame. A shadow's first tile bakes on
  the calling thread (at mount, when nothing else can be shown) and a run's
  resting target bakes at install, so the run ends exact; every other radius
  step bakes off the frame (one per main-queue turn on iOS, a background
  thread on Android) while the nearest cached step stands in, and the model
  takes the exact tile when it lands. A run whose intermediate steps are not
  cached yet swaps to the next cached, rounder tile at the missing step's key
  time, so the shown corner is never tighter than the clip's.
- iOS discrete tile swaps carry the closing key time Core Animation's discrete
  mode requires (`keyTimes` has one more entry than `values`, ending at 1), so
  each swap lands where the radius crosses its step rather than on an even
  grid.
- iOS trusts a frame stamp only within the same ±1 s window as Android. A
  group held pending longer (a host that could not display, the app inactive)
  or a stamp from a rescaled clock starts now instead of beginning fully
  elapsed.
- `canonicalizeClipPresentation` validates and canonicalizes in one pass: the
  shadow colour, the geometry and the rotation were each parsed twice per
  `setFrame`. The iOS packet reader reads the array length once per
  presentation instead of once per value.

## [0.4.6](https://github.com/kbrattli/react-native-smooth-clip-view/releases/tag/v0.4.6) — 2026-09-20

- Draw `continuous` corners on Android as a Figma smoothed corner (smoothing
  0.6) instead of a single cubic pulled towards the corner point. The apex now
  matches a circular corner of the same radius and the shoulders ease in from
  1.6 × the radius, so a radius reads the same as on iOS and as
  `react-native-fast-squircle` at `cornerSmoothing={0.6}`. Clip, shadow, and hit
  testing share the path. The per-frame rebuild still allocates nothing and
  does no trigonometry unless a shoulder has to be shortened to fit.
  Existing Android `continuous` clips become visibly rounder at the same radius.

## [0.4.5](https://github.com/kbrattli/react-native-smooth-clip-view/releases/tag/v0.4.5) — 2026-09-20

- Run native `animateTo` for uniform `continuous` clips. The autonomous gate now
  requires uniform corner radii and an unchanged curve instead of circular
  corners, so iOS animates `cornerRadius` under a constant `cornerCurve` with no
  mask. Unequal radii and curve changes still return `null`.

## [0.4.4](https://github.com/kbrattli/react-native-smooth-clip-view/releases/tag/v0.4.4) — 2026-09-11

- Allow the Expo 56 runtime baseline (React Native 0.85.3, Reanimated 4.3.1, Worklets 0.8.3).

## [0.4.3](https://github.com/kbrattli/react-native-smooth-clip-view/releases/tag/v0.4.3) — 2026-09-11

### Rotate and fade the whole clip

Animate rotation and opacity alongside clip geometry on iOS and Android. The
aperture, its content, and its shadow move and fade together inside the fixed
host, using the existing controller and atomic group APIs.

- **Rotation:** pass degree or radian strings such as `'12deg'` or `'0.2rad'`.
  Rotation is clockwise around the current aperture center, after content
  translation and scale. Angles interpolate numerically, so `'720deg'` animates
  two full turns from zero. Interruption snapshots preserve those turns.
- **Group opacity:** set `opacity` to fade content and shadow together, including
  overlapping children. Finite values clamp to `[0, 1]`; spring rendering clamps
  opacity while preserving the spring's internal motion state.
- **Animation continuity:** rotation and opacity participate in timing and
  spring animations, cancellation snapshots, and background spring pause/resume.
  Explicit spring velocity applies to these channels too.
- **Touch and accessibility:** hit testing follows the rotated aperture, including
  clips rotated back into the viewport. Fully transparent content accepts no new
  touches and is hidden from accessibility.
- **Rendering:** appearance updates use native compositor properties without
  Yoga layout work or rebuilding unchanged clipping paths. Translucent groups
  may require offscreen compositing.
- **Types and validation:** export `ClipRotation`, include rotation and opacity in
  canonical presentations, and reject malformed angles or nonfinite values
  atomically. Add JavaScript and native regression coverage for these behaviors.

### Usage and upgrade notes

`rotation` defaults to `'0deg'` and `opacity` to `1`. Presentations are complete:
omitting either field resets it to its default. Snapshots return rotation in
radians. See [Rotate and fade a clip](./README.md#rotate-and-fade-a-clip) for a
controller example.

**Rebuild your native app after upgrading**, and run `pod install` on iOS. The
native presentation protocol has changed; JavaScript from 0.4.3 must run with the
matching native library, rather than an older binary updated only through OTA.

[All changes since 0.4.2](https://github.com/kbrattli/react-native-smooth-clip-view/compare/v0.4.2...v0.4.3)

Earlier release notes are available on [GitHub Releases](https://github.com/kbrattli/react-native-smooth-clip-view/releases).
