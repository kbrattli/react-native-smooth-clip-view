# react-native-smooth-clip-view

[![npm version](https://img.shields.io/npm/v/react-native-smooth-clip-view.svg)](https://www.npmjs.com/package/react-native-smooth-clip-view)

Layout-free animated rounded clipping for React Native Fabric.

`SmoothClipView` keeps a fixed maximum Yoga footprint while a reusable driver
updates only the native clipping layer. It is
useful for expanding cards, sheets, maps, media, zoom transitions, and other reveals where
animating layout width and height cause lag because of yoga/fabric calculating layout every frame.

In other words, it makes animating width height on Reanimated a cheap operation.

## Requirements

- React Native 0.86 or newer with the New Architecture enabled
- React Native Reanimated 4.5 or newer
- React Native Worklets 0.10 or newer
- iOS 16.4 or newer
- Android API 26 or newer

The package supports iOS, Android, and React Native Web. It does not include a
legacy Paper implementation.

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
fans the seven-scalar presentation out to all mounted hosts. Interactive
updates avoid Yoga and ShadowTree commits.

For transitions whose endpoint is known, let Core Animation interpolate on the
render server:

```tsx
const expandFromReact = () =>
  driver.react.animateTo(
    createClipPresentation(
      { x: 0, y: 0, width: 320, height: 480, radius: 24 },
      0,
      0
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
    driver.ui.setScalars(clip.x, clip.y, clip.width, clip.height, clip.radius, 0, 0);
  })
  .onEnd(() => {
    driver.ui.animateTo(createClipPresentation(expandedClip), {
      type: 'spring',
      initialVelocity: 'inherit',
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

### Driver

- `useSmoothClipDriver(initialPresentation, options)` returns one hybrid driver
  whose writable `presentation` SharedValue contains clip geometry and content
  translation. Passing a `ClipGeometry` remains supported and initializes both
  translations to zero.
- `driver.ui` is the synchronous UI-worklet interface. `beginInteraction()`
  freezes a transition at visible presentation state; `set()`, `animateTo()`,
  and `cancel()` change ownership atomically.
- `driver.ui.setScalars(x, y, width, height, radius, tx, ty)` is the per-frame
  hot path: it writes geometry straight to native without touching
  `driver.presentation`, skipping SharedValue bookkeeping for high-frequency
  streams such as gestures. `driver.presentation.value` is stale after hot
  writes by design; `beginInteraction()` remains the source of truth for
  visible geometry, and `animateTo()` after hot writes starts from the native
  registry's latest value rather than the stale SharedValue. Do not interleave
  `setScalars` with `presentation.value` writes on the same driver.
- Spring `initialVelocity` is one normalized scalar along the current-to-target
  trajectory, in units of the remaining distance per second (`1` covers the
  remaining distance in one second). Every geometry channel continues with the
  same normalized rate, so grab/release preserves the felt direction and
  speed. `'inherit'` (the default) estimates the scalar from the last two
  interactive samples on iOS and Android; samples older than 100 ms — and the
  web fallback — fall back to zero.
- `driver.react` exposes `beginInteraction`, `set`, `animateTo`, and `cancel`
  as Promises (`setScalars` is UI-worklet-only). React code never blocks
  waiting for main/UI-thread work. An immediate animation request resolves
  before its completion callback is delivered.
- `animateTo()` transfers ownership to native animation. Timing uses
  cubic Bézier control points; springs accept mass, stiffness, damping, and an
  explicit normalized velocity or `'inherit'` (the default). Keyframes accept
  validated, monotonically increasing offsets from zero through one.
- `cancel()` freezes visible presentation by default. Pass `'target'` as its
  behavior to jump to the requested endpoint.
- `options.onAnimationComplete` fires once per animation with its ID and
  `finished` state, including cancellation, replacement, participant unmount,
  and native-side rejection (`animateTo` then returns `0` and one
  `finished: false` completion is delivered).

Do not call `driver.ui` from React code — it throws on the React runtime; use
`driver.react` there. During a native transition, `driver.presentation.value`
is the requested target, not a per-frame mirror of the native presentation
layer. `beginInteraction()` returns geometry normalized against the host
bounds, so a clip that extended beyond the host comes back clamped. Start
gestures with `beginInteraction()`: interactive writes issued while native
still owns rendering are dropped.

### `SmoothClipPresentation`

```ts
type SmoothClipPresentation = Readonly<{
  clip: ClipGeometry;
  contentTranslateX: number;
  contentTranslateY: number;
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
}>;
```

Values use React Native points/DIPs. Native code rejects non-finite updates,
intersects the requested rectangle with the actual host bounds, prevents
negative sizes, and clamps `radius` to half of the visible shortest edge.

### `normalizeClipGeometry`

`normalizeClipGeometry(geometry, bounds)` mirrors the native normalization
contract for tests and non-native calculations. Native bounds remain
authoritative at render time.

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
- Borders, shadows, host corner styles, host `overflow`, per-corner radii, and
  externally applied anisotropic transforms are unsupported.
- Version 0.1.0 supports one uniform corner radius.
- On web, the implementation uses CSS `clip-path` on the fixed host, so
  descendant percentages and right/bottom anchoring still resolve against the
  maximum footprint.

## Example and development

The [`example`](./example) workspace is an Expo SDK 57 app that exercises the
package through its public import on iOS, Android, and web.

```sh
npm install
npm run example -- ios
npm run example -- android
npm run example -- web
```

Run the repository checks with:

```sh
npm run lint
npm run typecheck
npm test
npm run prepare
npm run example -- build:web
```

## License

MIT
