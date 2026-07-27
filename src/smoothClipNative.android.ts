import { TurboModuleRegistry } from 'react-native';
import type { Spec } from './NativeSmoothClipModule';

// A Java/Kotlin TurboModule host function cannot be invoked synchronously from
// the Worklets UI runtime. The Android module therefore installs worklet-callable
// C++ host functions via TurboModuleWithJSIBindings. Resolving the module runs
// that installer synchronously (see TurboModuleManager), after which the driver
// uses the installed `global.__SmoothClipView` on both the UI and JS runtimes.
TurboModuleRegistry.getEnforcing<Spec>('NativeSmoothClipModule');

const bindings = (global as unknown as { __SmoothClipView?: Spec })
  .__SmoothClipView;

if (bindings == null) {
  throw new Error(
    '[SmoothClipView] Native JSI bindings are not installed. Rebuild the Android app after updating this package.'
  );
}

export default bindings;
