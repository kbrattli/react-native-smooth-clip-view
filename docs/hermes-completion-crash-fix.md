# Hermes completion crash: root cause and fix

Status: fixed and verified on September 1, 2026.

## Summary

Repeatedly dismissing and reopening the Gallery or Zoom examples could crash
Hermes with `EXC_BAD_ACCESS` on the React JavaScript thread. The animation
rendered correctly and the failure occurred during completion, teardown, or the
next mount.

The completion rewrite made the failure easier to trigger by retaining consumer
worklets for an animation's lifetime, but that was not the complete root cause.
The remaining crash came from worklets capturing the TurboModule proxy itself
and looking up methods on that proxy after an overlay had been destroyed and
remounted.

The fix has two parts:

1. Completion ownership is back on the React Native runtime. Native sends only
   primitive completion data through the existing event emitter; no arbitrary
   consumer callback is retained on the UI runtime.
2. UI worklets capture direct native host functions at module initialization.
   They no longer retain the TurboModule object or perform property lookups on
   it while an animation is running.

The raw-frame geometry and autonomous native rendering work remain unchanged.
The fix adds no per-frame work.

## Observed failure

All collected crashes had the same important characteristics:

- Hermes `EXC_BAD_ACCESS` on the React JavaScript thread.
- Common frames included `getNamedWithReceiver`,
  `getNamedDescriptorUnsafe`, or property enumeration below
  `consoleTaskRun`.
- No clipping, geometry, Core Animation, or rendering frame appeared in the
  crashing stack.
- The visual animation reached its landing frame before the failure.
- A first close could succeed while a later open or close crashed, implicating
  cross-run or cross-mount lifetime state.
- The failure reproduced with Reanimated 4.5.1 and Worklets 0.10.4.

The last pre-fix report produced during verification was
`SmoothClipViewExample-2026-09-01-144758.ips`.

## Problematic architecture

The staged controller rewrite moved completion ownership into the UI runtime:

```text
native terminal event
  -> React Native event listener
  -> UI task
  -> UI-global per-run lookup
  -> retained consumer worklet
  -> captured React callback scheduled back to React Native
```

That introduced several unnecessary lifetimes:

- A UI-global registry stored one record per animation.
- Arbitrary consumer worklets remained reachable until completion.
- Example completion closures captured React lifecycle callbacks such as
  `onClosed`.
- Completion crossed the React Native/UI boundary twice.

Removing that callback registry reduced the lifetime chain, but repeated mounts
still crashed. That result showed completion routing alone was not the complete
cause.

## Confirmed root cause

Controller and group worklets captured the complete TurboModule object and
invoked methods through it:

```ts
nativeHost.animateTiming(...);
nativeHost.snapshotCurrent(...);
```

Those expressions require Hermes to resolve a named property on the retained
TurboModule proxy. After an overlay/controller lifecycle ended, a later worklet
could encounter a stale remote proxy while starting or completing the next run.
That directly matches the named-property access functions in the crash stacks.

The corrected implementation extracts each host function once:

```ts
const animateTimingHostFunction = nativeHost.animateTiming;
const snapshotCurrentHostFunction = nativeHost.snapshotCurrent;
```

Worklets call only those direct functions:

```ts
animateTimingHostFunction(...);
snapshotCurrentHostFunction(...);
```

This removes the animation-time and remount-time property lookup on the
TurboModule proxy. The same correction is applied to controller and group host
functions because `react-native-screen-transitions` relies heavily on groups.

## Corrected completion architecture

The final path is:

```text
native terminal event
  -> module-lifetime React Native listener
  -> controller listener selected by primitive driver ID
  -> optional React callback / Promise resolution on React Native
```

Native completion data contains only:

- `driverId`
- `animationId`
- `completionTag`
- `finished`

UI-runtime callers may supply a nonnegative signed 32-bit `completionTag` to
identify a run. React-owned runs use private negative tags internally; those
tags are normalized to `0` before reaching public callbacks. This gives React
Promises deterministic completion routing without adding another native event,
request map, or native-to-React round trip.

The native event subscription remains installed for the module lifetime.
Individual controllers add and remove lightweight listeners from an RN-owned
map. This avoids removing the underlying TurboModule event subscription while
its callback may be executing.

## Lifecycle ownership

Controller cleanup also stays on the React Native runtime:

```text
React unmount
  -> detach controller completion listener
  -> settle outstanding React Promises as interrupted
  -> mark the UI-facing disposed value
  -> call native destroyDriver
  -> native forwards destruction to its UI thread when required
```

No UI-global run registry needs to be enumerated or cleared during teardown.
On Android, Kotlin forwards destruction to the UI thread before entering the
C++ registry. iOS already dispatches off-main destruction to the main thread.

## Discarded fix

An earlier experiment added `prepareAnimation()`, another TurboModule event,
extra Objective-C++/C++/Kotlin event plumbing, a second request map, and an
additional Promise round trip. It still crashed and introduced new subscription
delivery races. It was removed completely and is not part of the final design.

Raw off-host geometry was retained because neither the crash stacks nor the
runtime experiments implicated it.

## Example integration

Gallery and Zoom use a constant close tag and an RN-owned completion callback.
After native landing, source visibility is restored and React teardown is moved
to a fresh React Native animation-frame task. This keeps React lifecycle changes
outside the native event delivery task without sending a closure through the UI
runtime.

Rejected or interrupted closes recover the visible overlay instead of tearing
down the route. Opening visuals may mirror native timing, but only the native
terminal event owns successful close teardown.

## Performance impact

There is no additional per-frame work:

- `ui.setFrame` still performs one scalar JSI call.
- Timing and spring interpolation remain native and autonomous.
- Completion adds one primitive integer carried by the existing terminal event.
- Listener lookup and Promise resolution happen once per terminal event.
- Direct host-function calls avoid repeated TurboModule property lookup.

The only persistent overhead is one module-level event subscription and small
RN-owned maps containing active controller listeners and React runs.

## Verification

Post-fix runtime verification on the iOS simulator completed without a crash:

- Gallery: four complete open/dismiss cycles.
- Gallery: interrupted short-drag recovery followed by dismissal.
- Zoom: three complete open/dismiss cycles.
- The source tile/card was restored after every successful close.
- No crash report newer than the pre-fix 14:47 report was created.

The final code also passed:

- TypeScript typecheck.
- ESLint.
- 73 Jest tests across 10 suites.
- Android library unit tests.
- Android example debug build for every configured ABI.
- iOS native XCTest target.
- `react-native-screen-transitions` typecheck and package build against the
  linked library.
- npm package dry-run.

## Regression rules

Future controller changes should preserve these constraints:

1. Do not store arbitrary consumer callbacks or worklets in the UI runtime.
2. Do not capture a TurboModule proxy in a long-lived or scheduled worklet;
   capture direct host functions instead.
3. Keep terminal event routing and React Promise ownership on the React Native
   runtime.
4. Use primitive IDs or tags across runtime boundaries.
5. Do not add per-frame completion or lifecycle bookkeeping.
6. Validate repeated mount, open, dismiss, interruption, and remount cycles—not
   only a single successful animation.
