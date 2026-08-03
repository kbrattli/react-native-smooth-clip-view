# Publishing checklist

Current state (2026-08-03): **0.2.7 is tagged (`v0.2.7`) and released on
GitHub; npm still serves 0.2.5 as `latest`.** When publishing, use the
"publish an existing tag as-is" flow below against `v0.2.7`. Tags `v0.2.6`
(superseded by the 0.2.7 correctness follow-up before it was ever published)
and `v0.2.3` (superseded by 0.2.4) remain permanently npm-less.

0.2.6 is Android-only — `git diff v0.2.5..v0.2.6 -- ios/` touches nothing but a
new test file. It carries the Java-Choreographer frame-loop migration, the
frame-clock anchor's `min()` rebase (Reanimated phase parity), the outline
quantization fix (derived far edge plus sub-pixel placement on the view's own
translation), and monotone cubic keyframe interpolation. The outline-redraw
commit that briefly sat on main was reverted before release and never shipped —
`invalidateOutline()` already schedules the traversal; see
`docs/android-frame-clock-anchor.md`.

Note that the changelog `npm run release` generates lists that reverted commit
alongside its revert. That is inherent to conventional-changelog and is
explained in the published release notes rather than edited out.

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
npm run pack:check | grep cpp/      # cpp/ headers must ship
cd example/android && ./gradlew :react-native-smooth-clip-view:externalNativeBuildDebug -PreactNativeArchitectures=arm64-v8a
./gradlew :react-native-smooth-clip-view:externalNativeBuildRelease -PreactNativeArchitectures=armeabi-v7a,arm64-v8a,x86,x86_64 && cd -
cd example/ios && pod install && xcodebuild test \
  -workspace SmoothClipViewExample.xcworkspace \
  -scheme SmoothClipView-Unit-Tests \
  -destination 'platform=iOS Simulator,id=<sim-udid>' \
  CODE_SIGNING_ALLOWED=NO && cd -
npm run release        # release-it: version bump, changelog, tag, npm publish, GitHub release
```

Three gotchas in that block, each of which has cost a debugging round:

- **`externalNativeBuildRelease`, not `...RelWithDebInfo`.** RelWithDebInfo is
  the CMake build-type directory name, not a Gradle task; asking for it fails
  with "task not found". The release task builds all four ABIs — a debug
  single-ABI build leaves the shipped compile unproven.
- **`xcodebuild test` needs an explicit `-destination`.** Without one it
  defaults to "My Mac (Designed for iPad)" and dies on code signing. Get a UDID
  from `xcrun simctl list devices available`.
- **A new file under `ios/tests/` needs `pod install` before Xcode sees it.**
  The test spec globs the directory, but the file references are resolved at
  install time.

### Splitting the release from the npm publish

To tag and announce without publishing (e.g. the publish is someone else's
step), skip just that one operation:

```sh
GITHUB_TOKEN=$(gh auth token) npx release-it --ci --no-npm.publish
```

`release-it` needs a token of its own — it talks to the API directly and does
not shell out to `gh`, so an authenticated `gh` alone is not enough. Add
`--dry-run` first to confirm the computed version and that npm publish really is
absent from the plan. Afterwards the tag is publishable as-is with the flow
above.

After publishing, flip any consumer that installed a packed tarball
(`file:` spec) back to the semver range and run a real `npm install` so the
lockfile records the registry tarball.
