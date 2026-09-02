# Publishing checklist

Run the complete public, native, and packaging checks before cutting a release:

```sh
npm run typecheck
npm run lint
npm test -- --runInBand
npm run test:android
npm run prepare
npm run pack:check
```

Compile the Android native library for both debug and release. The release task
must cover all shipped ABIs:

```sh
cd example/android
./gradlew :react-native-smooth-clip-view:externalNativeBuildDebug \
  -PreactNativeArchitectures=arm64-v8a
./gradlew :react-native-smooth-clip-view:externalNativeBuildRelease \
  -PreactNativeArchitectures=armeabi-v7a,arm64-v8a,x86,x86_64
```

Install pods before running the iOS tests so newly added test sources are present
in the generated project:

```sh
cd example/ios
pod install
xcodebuild test \
  -workspace SmoothClipViewExample.xcworkspace \
  -scheme SmoothClipView-Unit-Tests \
  -destination 'platform=iOS Simulator,id=<sim-udid>' \
  CODE_SIGNING_ALLOWED=NO
```

Verify the packed file list includes `cpp/`, then use `npm run release` to bump,
tag, publish, and create the GitHub release.
