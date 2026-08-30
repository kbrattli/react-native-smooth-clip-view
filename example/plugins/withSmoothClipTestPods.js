const { withPodfile, withPodfileProperties } = require('expo/config-plugins');

// Autolinking alone does not attach a pod's test specs, and android/ + ios/
// are CNG outputs — prebuild regenerates the Podfile from the template, so a
// hand edit would not survive (and never reaches CI, which prebuilds from a
// clean checkout). Re-declare the library pod with :testspecs here instead so
// the SmoothClipView-Unit-Tests scheme exists in every generated workspace.
// If the template ever drops the anchor line this plugin becomes a no-op and
// CI's scheme assertion fails loudly rather than silently skipping the tests.
const TEST_POD_BLOCK = [
  '',
  '  # Re-declare the library pod to attach its XCTest spec (autolinking alone',
  '  # does not wire test specs); run them with:',
  '  #   xcodebuild test -workspace SmoothClipViewExample.xcworkspace \\',
  "  #     -scheme SmoothClipView-Unit-Tests -destination 'platform=iOS Simulator,name=iPhone 17 Pro'",
  "  pod 'SmoothClipView', :path => '../..', :testspecs => ['Tests']",
].join('\n');

module.exports = function withSmoothClipTestPods(config) {
  // Expo's precompiled modules must match React Native's exact Fabric ABI.
  // This fixture deliberately tracks the workspace RN version, so compile the
  // Expo modules from source instead of accepting a preregistration crash in
  // AppContext before SmoothClipView can mount.
  config = withPodfileProperties(config, (propertiesConfig) => {
    propertiesConfig.modResults.EXPO_USE_PRECOMPILED_MODULES = 'false';
    return propertiesConfig;
  });

  return withPodfile(config, (podfileConfig) => {
    const { contents } = podfileConfig.modResults;
    if (!contents.includes(":testspecs => ['Tests']")) {
      podfileConfig.modResults.contents = contents.replace(
        /^([ \t]*config = use_native_modules!\(config_command\)[ \t]*)$/m,
        `$1\n${TEST_POD_BLOCK}`
      );
    }
    return podfileConfig;
  });
};
