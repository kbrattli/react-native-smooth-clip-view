# Changelog

## Unreleased

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
  blur or colour changes. Uniform radii only; unequal radii keep the blur
  path. Default stays `"blur"`.
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
