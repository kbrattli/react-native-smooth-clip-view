# Changelog

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
