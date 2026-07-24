# react-native-smooth-clip-view

[![npm version](https://img.shields.io/npm/v/react-native-smooth-clip-view.svg)](https://www.npmjs.com/package/react-native-smooth-clip-view)

Layout-free animated rounded clipping for React Native Fabric.

`SmoothClipView` keeps a fixed maximum Yoga footprint while Reanimated sends
one atomic clip geometry update to the native view on the UI runtime. It is
useful for expanding cards, sheets, maps, media, zoom transitions, and other reveals where
animating layout width and height cause lag because of yoga/fabric calculating layout every frame.

In other words, it makes animating width height on Reanimated a cheap operation.

## Requirements

- React Native 0.85 or newer with the New Architecture enabled
- React Native Reanimated 4.3 or newer
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
} from 'react-native-smooth-clip-view';
import {
  interpolate,
  useDerivedValue,
  useSharedValue,
  withTiming,
} from 'react-native-reanimated';

const initialClip: ClipGeometry = {
  x: 120,
  y: 180,
  width: 80,
  height: 80,
  radius: 40,
};

export function ClipExample() {
  const [expanded, setExpanded] = useState(false);
  const progress = useSharedValue(0);
  const animatedClip = useDerivedValue<ClipGeometry>(() => ({
    x: interpolate(progress.value, [0, 1], [120, 0]),
    y: interpolate(progress.value, [0, 1], [180, 0]),
    width: interpolate(progress.value, [0, 1], [80, 320]),
    height: interpolate(progress.value, [0, 1], [80, 480]),
    radius: interpolate(progress.value, [0, 1], [40, 24]),
  }));

  const toggle = () => {
    const next = !expanded;
    setExpanded(next);
    progress.value = withTiming(next ? 1 : 0);
  };

  return (
    <View>
      <SmoothClipView
        initialClip={initialClip}
        animatedClip={animatedClip}
        style={styles.host}
      >
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

`initialClip` must equal `animatedClip.value` when the component mounts. This
lets native rendering start with the correct clip before the first UI-runtime
command is dispatched.

## API

### `SmoothClipView`

`SmoothClipViewProps` extends React Native `ViewProps` and adds:

| Prop | Type | Description |
| --- | --- | --- |
| `initialClip` | `ClipGeometry` | Clip rendered synchronously at mount. |
| `animatedClip` | `SharedValue<ClipGeometry>` | Geometry observed on the Reanimated UI runtime. |
| `children` | `ReactNode` | Content rendered inside the fixed host. |

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
yarn
yarn example ios
yarn example android
yarn example web
```

Run the repository checks with:

```sh
yarn lint
yarn typecheck
yarn test
yarn prepare
yarn example build:web
```

## License

MIT
