# Publishing checklist

Current state (2026-07-29): tag `v0.2.3` exists and is pushed, but **npm has
only 0.2.2** — the tag↔npm invariant is broken until 0.2.3 (or a superseding
release) is published. Consumers on a `^0.2.2` range that use `animation.from`
silently lose the fused release handoff on a clean `npm ci` (object spreads
bypass TypeScript excess-property checks, so nothing fails at compile time).

## Publish an existing tag as-is (e.g. 0.2.3)

```sh
git worktree add ../scv-publish v0.2.3
cd ../scv-publish
npm ci                 # prepare hook runs bob build
npm run pack:check     # verify cpp/ ships in the tarball
npm publish
cd - && git worktree remove ../scv-publish
```

## Cut a new release from main (bump + tag + publish in one)

```sh
npm run typecheck && npm run lint && npm test
npm run test:android
cd example/android && ./gradlew :react-native-smooth-clip-view:externalNativeBuildDebug -PreactNativeArchitectures=arm64-v8a && cd -
cd example/ios && pod install && xcodebuild test -workspace SmoothClipViewExample.xcworkspace -scheme SmoothClipView-Unit-Tests && cd -
npm run release        # release-it: version bump, changelog, tag, npm publish, GitHub release
```

After publishing, flip any consumer that installed a packed tarball
(`file:` spec) back to the semver range and run a real `npm install` so the
lockfile records the registry tarball.
