# Unified hybrid clip driver — architecture and hardening pass (2026-07-27)

This document describes the architecture the package landed on and every change
made in the review/hardening pass that followed the deep review of the unified
hybrid driver change-set.

## Verdict that drove this pass

The architecture was judged **correct and kept**: interactive updates bypass
Fabric entirely, native transitions run without per-frame application code, and
the measured hot path is already near the platform minimum. What the review
found — and this pass fixed — were implementation defects: a dead `cancel()`
on iOS, a packaging break for consumers, ownership wedges after involuntary
stops, lifecycle races on teardown/reload, a spring-velocity unit error, and a
deadlock-capable marshalling strategy.

## Architecture

One driver (`useSmoothClipDriver`) owns a seven-scalar
`SmoothClipPresentation` (clip x/y/width/height/radius + content
translate x/y) and moves rendering authority between two owners:

```
INTERACTIVE ownership                      NATIVE ownership
─────────────────────                      ────────────────
UI-runtime SharedValue listener            driver.ui.animateTo / react.animateTo
  → one typed JSI host function              → one setup call into the registry
  → C++ registry (per-driver state)          → iOS: grouped CABasicAnimation /
  → fanout to registered host views                 CASpringAnimation /
  → direct CALayer writes (iOS)                     CAKeyframeAnimation in the
    / outline invalidation (Android)                CA render tree
                                             → Android: Choreographer-driven
No Fabric commands, no ShadowTree                   C++ frame loop integrating
commits, no Yoga work on any frame.                 bezier/spring/keyframes
                                             → zero JS/JSI work per frame;
                                               one completion event at the end
```

Three call surfaces:

- `driver.presentation` — writable SharedValue; the listener delivers changed
  values to native while ownership is interactive.
- `driver.ui.*` — synchronous worklet controls (`beginInteraction`, `set`,
  `setScalars`, `animateTo`, `cancel`). Throws on the React runtime.
- `driver.react.*` — Promise wrappers that hop to the UI runtime via
  `scheduleOnUI`; React code never blocks on main/UI-thread work.

The **native registry is authoritative** for what is on screen. JS mirrors
ownership (`ownership`, `activeAnimationId` shared values) but never mirrors
per-frame presentation during native animations.

### Architectural decisions taken in this pass

These are the load-bearing design choices added while fixing the defects:

1. **Off-main calls fail defined instead of blocking (iOS + Android).**
   The previous fix marshalled off-main callers with `dispatch_sync(main)`.
   That is deadlock-capable: worklets' `runOnUISync` executes on the *calling*
   thread while holding the UI-runtime mutex, and the main thread routinely
   blocks on that same mutex — a textbook ABBA cycle. Now: void entries
   (`setPresentation`, `destroyDriver`) dispatch async to main; value-returning
   entries return their documented failure sentinel (`0`, `handled: 0`, or a
   NaN presentation that makes JS keep its current value). Android enforces the
   same contract with a cached main-thread check (Looper-identified once, then
   a thread-id compare). Supported usage (worklets UI runtime = main thread)
   never hits these branches.

2. **Tombstone driver lifecycle + effect re-seed as the revival path.**
   `destroyDriver` with views still registered no longer erases the entry — it
   marks it `destroyed`, releases ownership, and the entry is erased when the
   last view unregisters. The hook's effect performs an authoritative
   take-ownership `setPresentation` seed on every run, which both creates the
   native entry before any view mounts and *revives* a tombstoned driver after
   a StrictMode/`<Activity>` effect replay. All other entry points
   (`beginInteraction`, `animate*`, `rejectAnimation`) are `find()`-guarded so
   stale scheduled calls can neither resurrect nor leak destroyed drivers.
   JS-side, the strong `statesById` index is attached in the effect and
   detached in cleanup (render only touches the WeakMap), making discarded
   renders leak-free and effect replays crash-free.

3. **Normalized spring-velocity contract.** `initialVelocity` (explicit or
   `'inherit'`-projected λ) is one normalized scalar: remaining distance per
   second along the current→target trajectory. iOS passes λ **unchanged** to
   every `CASpringAnimation` key path — CA's `initialVelocity` is itself
   normalized (its `settlingDuration` is independent of the from/to distance,
   which proves the convention). Android's integrator works in absolute DIP
   space, so it seeds each channel with λ·displacement. Both produce the same
   visual motion. The previous iOS code multiplied λ by per-keypath deltas,
   overstating launch velocity by the pixel distance (~300× on a 300 pt
   gesture).

4. **`scalarsStale` handoff correctness.** `driver.ui.setScalars` deliberately
   leaves `driver.presentation` stale. A new UI-runtime flag records hot
   writes so a subsequent `animateTo` passes `hasInteractiveStart: false` and
   native resolves the animation start from its own latest value — otherwise
   release-after-drag would snap back to the stale SharedValue. Any
   authoritative sync (`set`, `beginInteraction`, `cancel`, a delivered
   listener value) clears the flag.

5. **Timing-independent CA teardown.** Every deliberate animation teardown
   invalidates the shared `SmoothClipAnimationDelegate` before removing the
   animations. The running CA copies share that delegate object, so a late
   `animationDidStop` (CA may deliver it after the teardown returns) can no
   longer masquerade as a real stop — which previously caused spurious
   `finished:false` completions on layout restarts and a permanently frozen
   clip after backgrounding.

6. **Completion plumbing that survives teardown.** The C++ completion sink is
   mutex-guarded on both platforms (written from the JS thread, invoked on
   main; invoking under the lock also pins the owning module for the call).
   Android additionally gets a real teardown path: `SmoothClipModule.
   invalidate()` → JNI → `invalidateBindings()`, which clears the sink and
   releases the listener `jsi::Function`s *while their runtime is still
   alive*; `installBindings` clears leftover listeners as a safety net so a
   reload can never invoke functions from a destroyed runtime.

7. **Stable spring integration on Android.** The semi-implicit Euler
   integrator is substepped (≤ 1/240 s per step inside the 64 ms dt clamp),
   keeping it stable to stiffness/mass ≈ 230 000 instead of diverging at
   ≈ 976, with a bail-to-target guard if any channel ever goes non-finite.

8. **Sticky prop state in the Android manager.** Fabric only delivers changed
   props, so the per-view pending state is now sticky with a per-transaction
   `dirty` flag: a transaction touching only `initialClipRadius` no longer
   fabricates `driverId = 0` and silently detaches the view from its driver.
   The command-driven (`driverId={0}`) path applies its initial presentation
   directly again, restoring the pre-driver behavior this rewrite had lost.

9. **Honest benchmarking.** The stress harness now mounts only the selected
   implementation's driver (the grid is split per mode). Previously all three
   shared drivers ran a per-frame reaction + native call during *every*
   benchmark mode, contaminating comparisons.

## Changes by severity

### P0 — correctness blockers

| Fix | Files |
| --- | --- |
| `cpp/` added to the npm `files` whitelist — published installs could not compile on either platform (`SmoothClipRegistry.h` not in the tarball) | `package.json` |
| Cancel handled flag emitted as a **number** (`1.0/0.0`); a jsi bool made JS's `values[0] !== 1` fail on every call, leaving ownership wedged `NATIVE` and the clip frozen | `ios/SmoothClipTurboModule.cpp` |
| `synchronizeNativeCompletion` no longer ignores `finished:false` — involuntary stops (participant unmount, stripped animations) now release JS ownership; the stale-id guard already covers superseded animations | `src/nativeCompletion.ts` |
| `unregisterView` releases native ownership when the last participant leaves (both platforms) | `ios/SmoothClipRegistry.mm`, `android/.../SmoothClipRegistry.cpp` |
| Mutex-guarded completion sink (JS-thread writes vs main-thread invokes) | both registries |
| Android runtime teardown: listener reset on reinstall + `invalidate()` hook | `SmoothClipBindings.cpp`, `SmoothClipAndroid.h`, `SmoothClipBindings.kt`, `SmoothClipModule.kt` |
| Off-main fail-defined policy replacing `dispatch_sync(main)` (deadlock) | `ios/SmoothClipRegistry.mm`, `android/.../SmoothClipRegistry.cpp` |
| Remount/StrictMode safety: WeakMap-only render state, effect attach/detach, authoritative re-seed, tombstone destroy, `find()` guards on all animate/begin/reject entries | `src/driverState.ts`, `src/drivers.ios.ts`, `src/drivers.ts`, both registries |

### P1 — functional bugs

| Fix | Files |
| --- | --- |
| iOS spring `initialVelocity` normalized (pass λ unchanged; deltas removed) | `ios/SmoothClipView.mm` |
| Native-rejected `animateTo` now funnels through `rejectAnimation`, so every call on a live driver yields exactly one `finished:false` completion (completion-driven loops no longer stall); returns the standalone completion id | `src/drivers.ios.ts` |
| CA delegate `invalidated` flag (replaces same-tick `_ignoreAnimationCallback` reliance) | `ios/SmoothClipView.mm` |
| Spring rebuilds (layout change, foreground resume) run their own settling duration instead of being truncated by `MIN(remaining, settling)` and snapping mid-oscillation | `ios/SmoothClipView.mm` |
| Listener `last` cache records only values native actually observed — values dropped during native ownership stay eligible for re-delivery (no more silently stuck clip after completions) | `src/drivers.ios.ts` |
| `scalarsStale` flag: `animateTo` after `setScalars` starts from native's latest value | `src/drivers.ios.ts` |
| Android spring substepping + non-finite bail | `android/.../SmoothClipRegistry.cpp` |
| Android manager sticky props (absent `driverId` ≠ 0) + `driverId={0}` initial-clip apply restored; `commandIsAuthoritative` tracked on the view | `SmoothClipViewManager.kt`, `SmoothClipView.kt` |
| Mid-animation join reference skips peers without layout (a pre-layout peer reports `{0,0,0,0}` and would collapse the clip); falls back to the animation's start | `ios/SmoothClipRegistry.mm`, `ios/SmoothClipView.mm` (`smoothClipIsJoinable`) |

### P2 — hardening and parity

- Android: final-frame double fanout removed; frame-loop exception barrier
  (an fbjni exception can no longer `std::terminate` out of the C callback);
  choreographer confined to the main thread; consumer ProGuard keep rules
  (`android/proguard-rules.pro`) so minified consumer builds can't strip the
  JNI-referenced class/methods.
- iOS: signposts compiled into Debug via the podspec (previously dead code in
  every configuration); empty→empty transitions stay hidden for
  accessibility; missing main-thread asserts added.
- Web: driver-state attach/detach migration; documented that `ui.*` needs no
  runtime guard on web (single runtime) and `'inherit'` degrades to zero.
- Example: per-implementation grids (benchmark fairness).
- README: shipped-API accuracy (`react.setScalars` does not exist), normalized
  velocity semantics, completion contract incl. rejection, `setScalars` shown
  in the gesture example, `beginInteraction` clamped-geometry contract, and a
  0.0.x migration note for the removed `initialClip`/`animatedClip` props.

## Tests added

- **JS (`src/__tests__/drivers.ios.test.tsx` + `driverState`/`reactRequests`)**
  — numeric-vs-boolean cancel-flag contract (would have caught the dead
  `cancel()`); `finished:false` ownership recovery + dropped-value
  re-delivery; StrictMode-style effect replay (cleanup → re-run → revived
  driver); rejected-`animateTo` completion; `beginInteraction` seed
  suppression (no echo); `setScalars`→`animateTo` start semantics; keyframe
  eight-scalar stride. 37 tests total, all green.
- **XCTest (`ios/tests/SmoothClipRegistryTests.mm`)** — ownership release on
  last-participant unregister; tombstone semantics (drop stale deliveries,
  revive on take-ownership seed, erase after last view); destroyed-driver
  entry points fail defined without resurrecting; off-main calls return
  sentinels without blocking; `CASpringAnimation.initialVelocity == λ` on all
  seven key paths.

## Verification status

| Check | Result |
| --- | --- |
| `npm run typecheck` | ✅ clean |
| `npm run lint` | ✅ 0 errors (9 pre-existing stress-harness warnings) |
| `npm test` | ✅ 37/37 |
| `npm run pack:check` | ✅ `cpp/SmoothClipRegistry.h` in the tarball |
| `npm run test:android` | ✅ build + JVM tests |
| Android NDK compile (`externalNativeBuildDebug`, arm64) | ✅ |
| iOS example app build (xcodebuild, arm64 + x86_64 sim) | ✅ |
| Simulator runtime smoke (iPhone 17 Pro): interactive 10-host oscillation, mode switching (driver teardown/re-create), native CA loop, 3× rapid grab→update→spring handoffs, background mid-spring → resume | ✅ no crashes, no assertions, no JS errors |
| Physical-device Release profiling (120 Hz) | ⏳ still the open gate for numeric performance claims |

## Upstream worklets crash found during smoke testing (worked around)

The grab→update→spring handoff reliably aborted the app
(`SIGABRT` in `jsi::Value::getObject` on the JS thread) — crash reports show
the identical stack hours *before* this hardening pass, so it is pre-existing.
Root cause is in **react-native-worklets 0.10.0**: the RN-side serialization
cache (`serializable.native.ts` → `cloneNonWorkletFunction`) hands out one
`__remoteFunctionRegistry` id per function forever, but
`SerializableRemoteFunction::RNOrigin::RNOriginProxy::~RNOriginProxy` deletes
that registry entry as soon as any transient UI-side proxy of the function is
garbage collected. The next `scheduleOnRN` for the same function then reads
`undefined` from the registry and asserts. `driver.react.*` captures
`resolveReactRequest` into a worklet on every call, so a UI-runtime GC between
calls (e.g. between two handoffs) killed the app.

Package-side workaround in `src/drivers.ios.ts`: a one-time module-scope
`scheduleOnUI` pins one UI-side reference to the resolver on `globalThis`, so
its proxy — and with it the registry entry — lives for the app lifetime.
Verified on-device: the previously crashing triple-handoff sequence now
completes. This should also be reported upstream to Software Mansion; the
workaround can be removed once worklets decouples registry cleanup from proxy
lifetime.

## Known limitations / deliberately deferred

- ~~An `animateTo` issued while the registry had zero registered views
  instant-completed at the target (`finished: true`), so a host mounting one
  frame later — e.g. inside a transparentModal route whose Fabric mount runs
  after the consumer's effect — statically applied the target and the clip
  jumped.~~ **Fixed in 0.2.1**: the built animation is now latched
  (`started = false`, held out of the render/frame path) and the first view
  registration rebases its clock and starts it with the full duration.
  Freeze-style cancellation of a never-started animation uses its start
  presentation (iOS: `canonicalFrozenPresentation`; Android falls out of
  `current = start`), and replacing a latch resolves the new start from the
  latch's start rather than `latest` (iOS: `resolvedAnimationStart` latch
  branch). A latch whose host never mounts completes `finished: false` on
  replacement, cancel, take-ownership write, or driver destruction. Full
  write-up — the race, the frame-by-frame behaviour on both platforms, the
  cost analysis, and the comparison with Reanimated's entering animations —
  in [`pending-animation-latch.md`](./pending-animation-latch.md).
- Spring joins for late-mounting views restart with the original launch
  velocity (visual-only, brief).
- The registry join clock is not rebased after long backgrounding (a
  late-joining view can snap if the app was suspended mid-transition).
- Process-global registry: multi-`RCTHost` (brownfield, two instances) shares
  one namespace; single-instance apps are unaffected.
- `beginInteraction` returns host-clamped geometry (documented contract).
- The CocoaPods test spec has no runnable scheme wired yet, so the XCTests
  compile with the pod but need scheme wiring to execute in CI.
- No Robolectric on Android (SDK 36 support was uncertain); the C++ registry
  logic is exercised through the shared-shape iOS XCTests instead.
