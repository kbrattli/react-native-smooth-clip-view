# Publishing checklist

Current state (2026-07-30): resolved — **0.2.5 is published to npm as
`latest`**. Tag `v0.2.3` remains permanently npm-less (superseded by 0.2.4
before it was ever published); every other tag matches a registry version.
Pending on main: the Java-Choreographer frame-loop migration and the
frame-clock anchor's `min()` rebase (Reanimated phase parity) ship as
**0.2.6** (run the "new release" flow below). The outline-redraw commit that
briefly sat on main was reverted — `invalidateOutline()` already schedules the
traversal; see `docs/android-frame-clock-anchor.md`.

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
