import NativeSmoothClipModule from './NativeSmoothClipModule';

// iOS/default: the C++ TurboModule host functions are already worklet-callable,
// so the driver captures them directly from the module.
export default NativeSmoothClipModule;
