# react-native-smooth-clip-view

[![npm version](https://img.shields.io/npm/v/react-native-smooth-clip-view.svg)](https://www.npmjs.com/package/react-native-smooth-clip-view)

https://github.com/user-attachments/assets/899235b3-de69-46d7-b6db-61bc54d80df8

<sub>Card zoom and shared-element gallery transitions, captured at 60fps — [direct clip](https://github.com/kbrattli/react-native-smooth-clip-view/blob/main/docs/media/smooth-clip-demo.mp4).</sub>

## High-performance geometry animations for React Native

`react-native-smooth-clip-view` lets you animate `x`, `y`, `width`, `height`, and `borderRadius` with Reanimated without triggering expensive layout work on every frame.

Instead of resizing the Yoga layout, `SmoothClipView` keeps a fixed footprint and updates only the native clipping layer. This makes geometry-heavy animations smooth and inexpensive—even for shared-element transitions, zoom transitions, expanding cards, reveals, sheets, maps, and media.

Use it for transitions that previously struggled with performance when animating layout dimensions directly.

## Requirements

- React Native 0.86 or newer with the New Architecture enabled
- React Native Reanimated 4.5 or newer
- React Native Worklets 0.10 or newer
- iOS 16.4 or newer
- Android API 33 or newer

The package supports iOS and Android. React Native Web and the legacy Paper
architecture are not supported; keep imports and rendered usage behind native
platform boundaries.

## Installation

Available from [npm](https://www.npmjs.com/package/react-native-smooth-clip-view):

```sh
npm install react-native-smooth-clip-view react-native-reanimated react-native-worklets
```

For iOS, install pods after adding the package:

```sh
cd ios && pod install
```

Follow the Reanimated installation instructions for your React Native setup.
Expo SDK 57 configures the required Babel plugin through `babel-preset-expo`.

## Usage

```tsx
import { useState } from 'react';
import { Button, StyleSheet, View } from 'react-native';
import {
  type ClipGeometry,
  SmoothClipView,
  createClipPresentation,
  useSmoothClipDriver,
} from 'react-native-smooth-clip-view';

const initialClip: ClipGeometry = {
  x: 120,
  y: 180,
  width: 80,
  height: 80,
  radius: 40,
};

export function ClipExample() {
  const [expanded, setExpanded] = useState(false);
  const driver = useSmoothClipDriver(
    createClipPresentation(initialClip, -initialClip.x, -initialClip.y)
  );

  const toggle = () => {
    const next = !expanded;
    setExpanded(next);
    const clip = next
      ? { x: 0, y: 0, width: 320, height: 480, radius: 24 }
      : initialClip;
    void driver.react.animateTo(
      createClipPresentation(clip, -clip.x, -clip.y),
      {
        type: 'timing',
        duration: 450,
        controlPoints: [0.42, 0, 0.58, 1],
      }
    );
  };

  return (
    <View>
      <SmoothClipView driver={driver} style={styles.host}>
        <View style={styles.content} />
      </SmoothClipView>
      <Button title="Toggle clip" onPress={toggle} />
    </View>
  );
}

const styles = StyleSheet.create({
  host: { width: 320, height: 480 },
  content: { width: 320, height: 480, backgroundColor: '#112743' },
});
```

The same driver can be passed to multiple hosts. One native registry update
fans the complete presentation out to all mounted hosts, including per-corner
radii, continuous curves, centered content scale, and `boxShadow`. Interactive
updates avoid Yoga and ShadowTree commits.

For transitions whose endpoint is known, let Core Animation interpolate on the
render server:

```tsx
const expandFromReact = () =>
  driver.react.animateTo(
    createClipPresentation(
      { x: 0, y: 0, width: 320, height: 480, radius: 24 },
      0,
      0,
      1,
      {
        color: 'rgba(0, 0, 0, 0.25)',
        offsetX: 0,
        offsetY: 2,
        blurRadius: 64,
        spreadDistance: 5,
      }
    ),
    {
      type: 'timing',
      duration: 450,
      controlPoints: [0.42, 0, 0.58, 1],
    }
  );
```

Native timing, spring, and keyframed transitions have no app callback between
setup and completion on iOS. Core Animation interpolates the clip and content
translation as one presentation. Android runs one C++ frame-loop driven by the
vsync clock with registry fanout; outline calculation and invalidation still
run on its UI thread. Springs are physically integrated per geometry channel
and finish when they settle below sub-pixel thresholds on both platforms.
Retargeting starts from visible state.

Blocked-thread behavior: a blocked JS thread never stalls a running
transition on either platform — no JS runs on the frame path. A blocked
main thread stalls it on Android (the frame loop and the View property
writes are main-thread-only by platform design; the RenderThread only
replays what the main thread records) but not on iOS, where the render
server advances installed Core Animations out of process. The Android
behavior is not recoverable through public APIs — RenderThread-driven
property animation (`RenderNodeAnimator`, what ripples use) is hidden API —
and it is also the coherent choice for this library: parallel Reanimated
content runs on the main thread on both platforms, so on Android the clip
and its content stall and resume together, while on iOS a main-thread stall
lets the natively animated channels keep moving past any Reanimated-driven
ones.
The same driver can be grabbed by a gesture without a visual jump:

```tsx
const gesture = Gesture.Pan()
  .onStart(() => {
    const visible = driver.ui.beginInteraction();
    dragStart.value = visible.clip.height;
  })
  .onUpdate((event) => {
    const clip = geometryForDrag(dragStart.value, event.translationY);
    // Per-frame hot path: writes straight to native without SharedValue
    // bookkeeping. Assigning driver.presentation.value also works.
    driver.ui.setScalars(
      clip.x,
      clip.y,
      clip.width,
      clip.height,
      clip.radius,
      clip.radius,
      clip.radius,
      clip.radius,
      clip.curve === 'continuous' ? 1 : 0,
      0,
      0,
      1,
    );
  })
  .onEnd((event) => {
    // The release event is fresher than the last onUpdate (on Android,
    // ACTION_UP carries a position no MOVE ever delivered). Pass the final
    // geometry as `from` so the animation starts from exactly that value —
    // it fuses a setScalars hot write with the handoff in one call.
    const clip = geometryForDrag(dragStart.value, event.translationY);
    // 'inherit' projects launch speed from the drag's last two samples. On
    // Android that sampling is opt-in — create the driver with
    // useSmoothClipDriver(initial, { velocityTracking: true }).
    driver.ui.animateTo(createClipPresentation(expandedClip), {
      type: 'spring',
      initialVelocity: 'inherit',
      from: createClipPresentation(clip),
    });
  });
```

## API

### `SmoothClipView`

`SmoothClipViewProps` extends React Native `ViewProps` and adds:

| Prop       | Type               | Description                             |
| ---------- | ------------------ | --------------------------------------- |
| `driver`   | `SmoothClipDriver` | Reusable hybrid clip driver.            |
| `children` | `ReactNode`        | Content rendered inside the fixed host. |

The host hides itself while the raw aperture has a zero extent. It drops out of
the accessibility tree and stops accepting touches whenever that aperture does
not intersect the host. Both platforms retain fractional geometry through their
native aperture paths.

### `boxShadow`

`SmoothClipPresentation.boxShadow` defines one outset shadow that always follows
the raw aperture:

```ts
type ClipBoxShadow = Readonly<{
  color?: ColorValue;
  offsetX: number;
  offsetY: number;
  blurRadius?: number; // CSS box-shadow blur semantics
  spreadDistance?: number;
}>;
```

Color defaults to opaque black; blur and spread default to zero. Put opacity in
the color alpha, matching React Native's `boxShadow` model. Blur is clamped to a
nonnegative value; negative spread remains valid. iOS lazily creates one
unmasked CALayer whose `shadowPath` is built from the raw aperture.
Android draws the same outset path with CSS-compatible offset, blur, spread,
color, and per-corner geometry instead of hardware elevation. Timing, spring, keyframe, streamed,
interrupted, and relatched presentations keep the shadow in the same native
ownership channel as the aperture.

Do not put `boxShadow`, legacy `shadow*`, `elevation`, or `filter.dropShadow` on
the `SmoothClipView` style. Those properties would create an independent shadow;
development builds report an error and sanitize them. Multiple shadows, inset,
CSS string parsing, and `filter.dropShadow` are intentionally unsupported.

### Driver

- `useSmoothClipDriver(initialPresentation, options)` returns one hybrid driver
  whose writable `presentation` SharedValue contains clip geometry and content
  translation. Passing a `ClipGeometry` remains supported and initializes both
  translations to zero.
- `driver.ui` is the synchronous UI-worklet interface. `beginInteraction()`
  freezes a transition at visible presentation state; `set()`, `animateTo()`,
  and `cancel()` change ownership atomically.
- `driver.ui.setScalars(x, y, width, height, topLeft, topRight, bottomRight,
  bottomLeft, curveCode, tx, ty, scale)` is the one per-frame hot path. It
  writes the complete geometry and content transform straight to native while
  preserving the current `boxShadow`, without touching
  `driver.presentation`, skipping SharedValue bookkeeping for high-frequency
  streams such as gestures. `driver.presentation.value` is stale after hot
  writes by design; `beginInteraction()` remains the source of truth for
  visible geometry, and `animateTo()` after hot writes starts from the native
  registry's latest value rather than the stale SharedValue. To start from a
  value fresher than the last hot write (a gesture's release sample), pass it
  as `animation.from` — `animateTo` then performs the hot write and the
  handoff in one call. `curveCode` is `0` for circular and `1` for continuous;
  values are validated as one transaction. Do not interleave `setScalars`
  with `presentation.value` writes on the same driver.
- Spring `initialVelocity` is one normalized scalar along the current-to-target
  trajectory, in units of the remaining distance per second (`1` covers the
  remaining distance in one second). Every geometry channel continues with the
  same normalized rate, so grab/release preserves the felt direction and
  speed. `'inherit'` (the default) estimates the scalar from the last two
  interactive samples on iOS and Android. On Android, sampling on the
  `setScalars` hot path is **opt-in**: pass
  `velocityTracking: true` to `useSmoothClipDriver` or `'inherit'` inherits
  zero after a hot-write drag (a dev-mode warning flags this). **Behavior
  change:** earlier releases always recorded on Android, so an existing
  `setScalars`-drag → inherit-spring handoff keeps its momentum only after
  adding the flag. The recording
  is a clock read plus channel copies on every per-frame write, so drivers
  that never hand off into an inherit spring skip it by default. iOS always
  records, and Android's declarative `presentation.value` channel always
  records too. How long the finger has been still since that last sample scales the
  result: full credit for one frame (16.7 ms), then a linear decay to zero at
  100 ms. A release straight out of a drag is therefore untouched, and holding
  still before releasing bleeds the momentum off smoothly instead of keeping
  all of it until 99 ms and none at 101 ms. Two writes landing inside the same frame
  (< 4 ms apart, e.g. a release-sample `from` seed right after the last drag
  write) coalesce into one sample, and an identical re-write is ignored, so a
  fused handoff can neither zero nor inflate the inherited velocity.
  Only interactive writes contribute samples. Internal freeze/join/resume and
  static-finalization writes do not, so grabbing a native animation cannot
  manufacture velocity for a later `'inherit'` spring; a subsequent drag (or
  explicit `animation.from`) supplies the release samples instead.
- `driver.react` exposes `beginInteraction`, `set`, `animateTo`, and `cancel`
  as Promises (`setScalars` is UI-worklet-only). React code never blocks
  waiting for main/UI-thread work. An immediate animation request resolves
  before its completion callback is delivered.
- `animateTo()` transfers ownership to native animation. Timing uses
  cubic Bézier control points — `ClipEasings` exports exact-form presets
  (`easeOutCubic` = `Easing.out(Easing.cubic)` etc.) so a parallel Reanimated
  animation can run the identical curve without hand-deriving it; springs
  accept mass, stiffness, damping, and an
  explicit normalized velocity or `'inherit'` (the default). Keyframes accept
  validated, monotonically increasing offsets from zero through one; there is
  deliberately no keyframe easing field — playback is linear between offsets
  and the frames encode the curve, which also expresses per-channel-nonlinear
  paths that no single time-warp could reproduce. Every
  kind accepts an optional `from` presentation — a fused take-ownership hot
  write issued immediately before the handoff, so the animation starts from
  exactly that value (pass `frames[0].presentation` for keyframes, which
  interpolate absolutely). A non-finite `from` rejects the whole call; against
  a held pending-animation latch, explicit `from` is the newer intent: it
  cancels that latch once with `finished: false`, records/applies `from`, then
  starts the replacement from that native value. Passive hook seeds and public
  `set`/`setScalars` writes still leave a held latch intact. `from` behaves the
  same on both platforms (it is driver-layer, not native): on iOS the seed
  stops any running Core Animation, applies `from` to the model layer, and
  installs timing, spring, or keyframe playback from that exact presentation in
  the same start transaction.
- `cancel()` freezes visible presentation by default. Pass `'target'` as its
  behavior to jump to the requested endpoint.
- `options.onAnimationComplete` fires exactly once per animation with its ID
  and `finished` state, including cancellation, replacement, and native-side
  rejection (`animateTo` then returns a fresh non-zero id whose single
  `finished: false` completion follows — key completion handling by the
  returned id, never by `0`). A valid pre-registration request carries its
  authoritative interactive start, creates the missing driver state and
  returns a real id. `0` — with no completion — is reserved for off-main,
  invalid-id, or otherwise unsupported dispatch: a missing-state native request
  with no authoritative start, any `driver.ui.animateTo` issued after the
  driver's hook has unmounted, and an invalid-parameter request issued before
  the driver's first seed reached native (validation rejections mint their
  `finished: false` completion only once the native entry exists). (The
  post-unmount case is decided on the UI runtime,
  because a destroyed driver and a not-yet-seeded one are the same missing
  registry entry to native — accepting it would build a latch nothing can start
  and nothing can cancel.) A host is displayable only while it is attached,
  foreground/window-visible, laid out, and positive-sized (the window's own
  `hidden`/scene state is not consulted — RN's single always-visible window
  makes it moot). Losing the last
  displayable host mid-flight — including temporary detach, zero-size layout,
  or app background — freezes and re-latches the exact remainder instead of
  consuming duration offscreen. Foreground/reattach resumes the same animation
  ID from that stored timing/keyframe phase or spring state.
  Parallel Reanimated clocks do **not** pause with it: a `withTiming` started
  beside `animateTo` keeps its wall-clock start, so after backgrounding it
  completes on its first resumed frame while the native run still animates its
  preserved remainder. Key teardown and state transitions off
  `onAnimationComplete` (or re-synchronize on `AppState`) rather than off a
  duration-matched Reanimated callback.
  With multiple hosts on one driver, a host becomes an installed participant
  only after its native animation starts. Temporary loss moves it to suspended;
  a rejoin restores active participation. Unregistering an installed/suspended
  host, or reaching completion while it remains suspended, makes the eventual
  completion `finished: false`. A host that stayed deferred because it was
  detached, unlaid-out, or zero-sized never poisons completion. `finished: true`
  means every installed participant either ran to the end or rejoined and did so.
- An `animateTo` issued before any host view can produce a visible frame (for
  example from an effect in the same commit that mounts the host, or inside a
  modal route whose subtree attaches to its window late) is held pending and
  starts with its full duration at the first moment a registered host can
  produce a frame — positive layout, window attach/visibility, and foreground
  state must all be present. This also covers an animation worklet that runs before the
  hook's seed worklet: the animation creates the state and the later passive
  seed cannot reset its ownership or active id. A pending animation owns the
  driver: ordinary take-ownership writes (`set`, `setScalars`, the hook's seed)
  are dropped while it is held. Replace it with another `animateTo`, override
  it with an explicit `animation.from`, or cancel it via `beginInteraction()`
  or `cancel()`. If no view ever becomes displayable, it survives until it is
  replaced, cancelled, or the driver is destroyed — at which point its single
  `finished: false` completion is delivered.

Do not call `driver.ui` from React code — it throws on the React runtime; use
`driver.react` there. During a native transition, `driver.presentation.value`
is the requested target, not a per-frame mirror of the native presentation
layer. `beginInteraction()` returns the raw canonical native snapshot, including
coordinates outside the host, so it can be handed directly to the next gesture
or animation without a coordinate conversion. Start gestures with
`beginInteraction()`: interactive writes issued while native still owns
rendering are dropped.

### Group driver

`useSmoothClipGroupDriver({ reduceMotion, onAnimationComplete })` coordinates
multiple drivers with one native group ID and one completion. Its worklet-safe
`ui` and Promise-based `react` interfaces expose:

- `beginInteraction(drivers)` to freeze every overlapping group atomically and
  return canonical visible snapshots in input order.
- `snapshotCurrent(drivers)` to sample presentation and readiness without
  changing ownership.
- `setBatch(entries)` to validate every entry before committing one native
  transaction.
- `animateTo(entries, animation)` for shared timing, spring, or linear
  keyframe progress. Membership is immutable for that group ID; a replacement
  is a new atomically installed group.
- `cancel(groupId, 'freeze' | 'finish')` to return every participant snapshot.

Groups wait until all participants have a visible, attached, laid-out,
positive-size host. The default `suspensionPolicy: 'pause'` freezes and
re-latches the whole group if any participant loses readiness; `'finish'`
applies every target. Complex-path native settlement is capability-gated—use
`getSmoothClipCapabilities()` and keep streaming with `setBatch` when
`autonomousComplexPathAnimation` is false.

### `SmoothClipPresentation`

```ts
type SmoothClipPresentation = Readonly<{
  clip: ClipGeometry;
  contentTranslateX: number;
  contentTranslateY: number;
  contentScale?: number;
}>;
```

Use the content translation fields when a clipped viewport must reveal a
fixed-size child without a separate Reanimated transform. Native transitions
animate clip position, bounds, radius, and content translation together.

### `ClipGeometry`

```ts
type ClipGeometry = Readonly<{
  x: number;
  y: number;
  width: number;
  height: number;
  radius: number;
  topLeftRadius?: number;
  topRightRadius?: number;
  bottomRightRadius?: number;
  bottomLeftRadius?: number;
  curve?: 'circular' | 'continuous';
}>;
```

Values use React Native points/DIPs. Native code rejects non-finite updates,
clamps negative dimensions to zero, and proportionally scales overlapping
corners against the requested rectangle with the CSS corner-overlap rule. It
does not clamp or intersect `x`, `y`, `width`, or `height` against the host.
The fixed `SmoothClipView` bounds are the final rendering viewport: content and
the aperture's outset shadow are cropped there, while the aperture does not
clip its own shadow. Content scale is centered on the native content container;
translation is independent and is not multiplied by scale.

`canonicalizeClipGeometry(geometry)` exposes the same host-independent geometry
rule for tests and other non-native calculations.

## Migrating from 0.0.x

Version 0.1.0 removes the `initialClip` and `animatedClip` props in favor of
the driver API: create a driver with `useSmoothClipDriver(initialPresentation)`,
pass it as the `driver` prop, and move per-frame updates from the
`animatedClip` SharedValue to `driver.presentation.value` (or
`driver.ui.setScalars`). Autonomous transitions move from Reanimated
`withTiming`/`withSpring` to `driver.ui.animateTo` / `driver.react.animateTo`.

## Layout and styling contract

- Give the host its fixed maximum `width` and `height`; clipping never changes
  Yoga layout.
- Put visual backgrounds inside `SmoothClipView`.
- Keep borders, shadows, rotation, and anisotropic transforms on an outer
  visual carrier rather than the clip host.
- Uniform circular corners use platform fast paths. Unequal or continuous
  corners use a fixed-topology portable path; Android intentionally does not
  claim pixel identity with Apple's proprietary continuous curve.

## Example and development

The [`example`](./example) workspace is an Expo SDK 57 app that exercises the
package through its public import on iOS and Android.

```sh
npm install
npm run example -- ios
npm run example -- android
```

Run the repository checks with:

```sh
npm run lint
npm run typecheck
npm test
npm run prepare
```

## License

MIT
