# Pending-animation latch — starting a transition that raced its own host (2026-07-28)

This document explains the 0.2.1 fix in full: the race it removes, what the
old behaviour actually put on screen, how the latch behaves frame by frame
on both platforms, what it costs, what it still cannot fix, and how the same
problem is solved in Reanimated's entering/layout animations.

The short version: an `animateTo` issued before any host view exists is no
longer thrown away. It is held un-started, and the first view registration
starts it with the clock rebased to that instant — the earliest moment at
which a running animation can produce a visible frame.

## Addendum (2026-07-28, evening): the latch is gated on displayability

The 0.2.1 latch started at the first `registerView`. Live diagnosis in a
consumer app (map overlay in a `transparentModal` route) proved that is
still too early: **a Core Animation animation committed while the host's
layer tree is detached from the render tree does not survive the later
attach commit.** RNScreens presents the modal's view controller
asynchronously (even with `animation: 'none'`), so registration — and the
CA install — happened while the subtree had no window; ~one frame after the
window attach, CA removed the animation (`animationDidStop finished:NO`) and
the layer snapped to its model values, which are the target. Symptom:
byte-identical to the pre-latch bug.

The fix generalizes the latch's own principle. "The earliest moment a
running animation can produce a visible frame" is not registration — it is
**displayability**: the view has layout AND is attached to a window
(`smoothClipCanDisplay`). Concretely:

- `animateTiming/Spring/Keyframes` latch unless at least one registered view
  is displayable (`anyDisplayableView`), not merely present.
- `registerView` starts a held latch only for a displayable view; a detached
  registration applies the latch's start rect and keeps holding.
- `SmoothClipView` overrides `didMoveToWindow` and calls
  `viewBecameDisplayable`, which starts a held latch (clock rebased to the
  attach) or completes a deferred install for a running animation. The
  install rides the attach commit — the same transaction that first makes
  the view visible — so the property "starts inside the transaction that
  makes it renderable" now holds for detached-subtree mounts too.
- The per-view install deferral (`_pendingAnimationInstall`) triggers on
  `!smoothClipCanDisplay`, not just missing layout, and first-layout joins
  wait for the window when there is none. A relayout while still detached
  re-arms the deferral instead of reinstalling (that install would die at the
  attach commit), and the keyframes install path uses the same gate.
- Android mirrors the gate (`entryDisplayable`: attached to window + real
  host geometry; `nativeViewBecameDisplayable` from `onAttachedToWindow`).
  Android has no CA-removal failure mode — its integrator applies values
  every frame — so there the gate only prevents burning clock time while
  nothing can be drawn.

Three registry holes found during the same diagnosis were fixed alongside:

1. **Last unregister mid-flight re-latches instead of completing.**
   Unmounting the last rendering host used to destroy the animation while
   `latest` already held the target, so a re-registering host statically
   snapped to it. Now the remainder is re-latched (start = the departing
   view's visible geometry, duration = remaining time, keyframes pruned) and
   the next displayable host resumes it. `destroyDriver` still cancels a
   latch that never finds a host, so the completion cannot hang. An
   un-started latch whose last view unregisters simply returns to its
   zero-view held state.
2. **A take-ownership write no longer cancels a held latch.** The hook's
   seed replays a SharedValue that an earlier `animateTo` already advanced
   to its target; cancelling the latch would seed the target and turn the
   pending animation into a static jump. A held latch is strictly newer
   intent than any value the seeder read, so the write is dropped. (This
   supersedes the "take-ownership write cancels the latch" completion
   trigger listed below; `beginInteraction`, replacement, cancel and destroy
   still do.)
3. **`canonicalFrozenPresentation` skips unlaid-out views** (the same
   `smoothClipIsJoinable` filter the join paths use) so freezing while a
   zero-geometry peer is registered can no longer collapse the clip to
   `{0,0,0,0}`.

Coverage note: the iOS gate, re-latch, seed-drop and freeze-filter behaviors
are pinned by `ios/tests/SmoothClipRegistryTests.mm`, including the deferred
install completing at window attach and the detached-relayout deferral. The
Android mirror has no JVM coverage (Robolectric is deliberately absent from
this repo), so it is exercised by the C++ compile gate and live verification.

One ordering fact worth knowing: the Reduce Motion check runs **before** the
latch, so an `animateTo` under Reduce Motion instant-completes at the target
with `finished: true` even with zero views. That is deliberate platform
behaviour, and it visually resembles this bug — check the setting before
debugging a "skipped" transition.

## The race

One JS commit produces two independent work items that both end on the main
thread, with no ordering guarantee between them.

1. **The Fabric mount transaction.** The committed shadow tree becomes real
   `UIView`s / `android.view.View`s on the main thread. `SmoothClipView`
   registers with the native registry from inside that transaction — iOS in
   `updateProps` (`smoothclip::registerView`), Android in
   `SmoothClipViewManager.onAfterUpdateTransaction`
   (`nativeRegisterView`). That call is the moment the native side learns a
   surface exists for the driver. For a screen presented as a modal it is
   extra-late: the view controller / fragment must be presented before its
   subtree attaches.
2. **The worklets UI-queue drain.** A consumer effect runs on the JS thread
   right after the commit and calls `driver.react.animateTo`, which is a
   `scheduleOnUI` of a worklet. The worklets runtime drains that queue on the
   main thread too, but on its own scheduling — it can win or lose against
   the mount transaction.

When the drain wins, `animateTiming` / `animateSpring` / `animateKeyframes`
execute against a driver entry (created by the hook's authoritative seed)
whose `views` list is still empty. There is a driver, a start, a target and a
curve — and no surface to render any of it on.

This is not "the animation fired too early". Nothing can appear on screen
before the view exists, so any clock that runs before that moment burns
progress invisibly. The question is only what the registry does with an
animation whose clock and conclusion exist while its renderer does not.

## What the old zero-views path put on screen

Before 0.2.1 the registry declared victory: it stored the target as the
driver's `latest`, emitted `finished: true`, released ownership back to
Interactive and dropped the animation. Milliseconds later the mount
transaction ran, `registerView` found no active animation, and did what it
does for a plain mount — statically apply `latest`, which was now the
target. The first frame the host ever displayed was the end state of the
transition.

Consumers animating other content on a separate clock (a Reanimated
`withTiming` progress value driving legends, dock, opacity) saw that content
glide normally while the clip teleported. The failure was silent: the
completion said `finished: true`, so nothing downstream could notice.

## The latch

`ActiveAnimation` gained one flag, `started`. It is set at build time from
`!state.views.empty()` and, when false, the fully-built animation — start,
target, curve, duration — is kept in the driver state and nothing else
happens. No timer, no polling, no deferral to a later frame. The animation
is started by the mount, not by a heuristic about when the mount might have
happened.

The invariant that makes every other branch safe:

> `started == true` ⇒ the animation has (or had) at least one participant.
> `started == false` ⇒ no view ever saw it, and `state.views` is empty.

Registration is the only writer of `started = true`, so the invariant cannot
drift.

### iOS

`registerView` classifies the driver into three cases before touching
anything: `startsLatch` (an animation exists and has not started),
`shouldReplay` (a started animation with existing peers — the mid-flight
join that already existed), or neither. For a latch it applies
`state.animation->start` to the fresh view rather than `state.latest`,
because `prepareAnimation` already overwrote `latest` with the *target* —
applying it there is exactly the jump the path exists to avoid. It then
stamps `startedAt = CACurrentMediaTime()` and flips `started` before any
elapsed-time math can run, and finally goes through the same
`dispatchActiveAnimationJoin` used by mid-flight joins. With the clock just
rebased, `elapsedMs ≈ 0`, so the installed transition carries the full
duration.

Two latch branches exist outside `registerView`:

- `canonicalFrozenPresentation` — freezing a never-rendered animation
  (`beginInteraction`, `cancel` without the target) must return the
  animation's start, not `latest`.
- `resolvedAnimationStart` — replacing a latch (an open→close before the
  host mounted) must resolve the new start from the previous latch's start,
  for the same reason.

`joinActiveAnimation` gained a defensive `!started` bail. It is unreachable
in the normal flow — a pending install implies the animation was dispatched,
which implies it started — but a join must never compute elapsed time
against an un-rebased clock.

The latch composes with the pre-existing *per-view* deferral, and the two
must not be conflated: `ActiveAnimation::started` is per-driver ("no view is
registered at all"), while `SmoothClipView`'s `_pendingAnimationInstall` is
per-view ("registered, but no layout yet, so a `CAAnimation` would have
nothing to animate between"). A view that registers during the mount
transaction typically has no layout yet, so the sequence is: registration
starts the latch and dispatches → the view stores a pending install →
`updateLayoutMetrics` arrives later in the same transaction and re-enters
the registry through `joinActiveAnimation`, which computes the remaining
duration from the rebased clock and installs the grouped CA animations. When
that `CATransaction` commits to the render server, the layer tree and its
animations arrive together.

### Android

Android needed no equivalent of `resolvedAnimationStart` or
`canonicalFrozenPresentation`, because `startAnimation` now sets
`animation.current = animation.start` unconditionally. `cancelAnimation`,
`beginInteraction`, `prepareAnimation`'s `visibleBefore` and
`registerViewAndroid`'s `visible` all read `current`, so freeze-at-start and
replace-from-start fall out of one assignment instead of four branches.

A latched driver is deliberately *not* pushed into `animatingDrivers()` and
no frame is scheduled, so the `AChoreographer` loop never runs for it. On
the first `registerViewAndroid`: the start presentation is delivered to the
new view synchronously, then the clock is rebased (`startedAtS`,
`lastFrameS`), the driver joins `animatingDrivers()` and `scheduleFrame()`
posts the vsync callback.

One Android detail matters for the first visible frame. Registration happens
in `onAfterUpdateTransaction`, before the platform layout pass, so the view
reports `width == 0` and the synchronous delivery normalizes to an empty
clip. The real metrics arrive from `onSizeChanged` →
`setViewHostGeometryAndroid`, which re-delivers `animation->current` — still
the start, because the choreographer has not run yet — with correct host
geometry, in the same traversal, before the frame is drawn. The first
*drawn* frame therefore shows the start, and the first *integrated* frame is
the next vsync.

## Semantics that changed

Exactly one completion per `animateTo` id is still guaranteed, but the
completion for a never-mounted animation changed:

| Situation | Before 0.2.1 | 0.2.1 |
| --- | --- | --- |
| `animateTo` with zero views, host mounts later | immediate `finished: true`, clip jumps to target | held, then runs full duration from the mount |
| `animateTo` with zero views, host never mounts | immediate `finished: true` | one late `finished: false` on replacement, cancel, `beginInteraction`, take-ownership write, or `destroyDriver` |

The new semantics are the truthful ones: `finished: false` means "the target
was not animated to", which is precisely what happened. The old
`finished: true` was a lie that also hid the bug.

Two consequences worth knowing:

- **A latch holds `Ownership::Native`.** Interactive (non take-ownership)
  writes are dropped while it is pending, and the JS-side listener cache
  does not record them either. Before 0.2.1 the instant-complete flipped
  ownership back to Interactive, so such writes were accepted. In practice
  the paths that matter take ownership explicitly: `beginInteraction`
  cancels the latch and returns its start. (Since the 2026-07-28 addendum,
  plain take-ownership *writes* — the hook's seed, `set`, `setScalars` — no
  longer cancel a held latch; they are dropped, because the latch is newer
  intent than any value those callers read. Cancel a latch explicitly via
  `beginInteraction`/`cancel` when overriding it is intended.)
- **A latch is unbounded in time.** If a host never mounts, the pending
  animation lives until the driver is destroyed (or replaced/cancelled).
  That is a deliberate trade: the alternative — expiring it after N ms —
  reintroduces a timing heuristic, and driver destruction already bounds it
  at hook unmount.

`animateTo` still returns a real, non-zero id synchronously, so the JS layer
treats a latch as a normal setup (`0` remains the rejection sentinel and is
not used here), and `driver.react.animateTo`'s promise resolves exactly as
before.

## Cost

**While latched:** the animation is a struct in a map. Android keeps it out
of `animatingDrivers()` so the choreographer loop does not run; iOS installs
nothing on any layer. There is no per-frame work of any kind.

**At start:** one boolean branch in `registerView` / `registerViewAndroid`,
one clock stamp, and the presentation write that registration performed
anyway. No allocation beyond the pre-existing path.

**During the animation:** unchanged. iOS runs grouped `CAAnimation`s in the
render tree; Android runs the single C++ vsync loop integrating seven
scalars. Zero JS/JSI work per frame either way.

Compare the consumer-side workaround this replaces — gating the first
`animateTo` on the host's `onLayout`: mount → layout → event marshalled to
JS → `setState` → re-render → effect → `scheduleOnUI` → main-thread drain →
`animateTiming`. That is one to three frames in which the host is visible
and frozen at its start, plus an extra render per open, plus a tax every
consumer has to rediscover. The latch is strictly earlier and strictly
cheaper, and when the mount happens to win the race the latch path is not
even taken — both orderings now converge on the same behaviour, which is
what makes it a fix rather than a workaround.

## Can this still be jittery, late, or lose part of the animation?

Worth answering precisely, because "the first frame I see is already
half-way through" has three distinct causes and the latch only removes one
of them.

**1. Does it start a frame late?** No. The start is synchronous inside the
registration that creates the surface; there is no frame in which the view
sits idle waiting for permission to animate. On iOS the animation is
installed in the same mount transaction (directly, or via the pending
install at first layout inside that transaction), so the layer tree and the
animation reach the render server together. On Android the first *drawn*
frame is the start presentation and integration begins at the next vsync —
which is also the earliest frame that could differ from the start, so
nothing is skipped and nothing idles.

**2. Does it make the UI thread heavier?** No — it is net lighter. A latch
costs nothing per frame, the start costs a branch, and the steady state is
the same CA / choreographer machinery as before. Removing the `onLayout`
gate additionally removes a `useState`, a re-render per open, a
main→JS→main round trip and an extra worklet dispatch from the consumer.

**3. Can the animation still be jittery?** Not from this change. Once
started, iOS frames are produced by the render server, so the clip keeps
moving at full refresh rate even if the app's main thread or the JS thread
stalls while heavy screen content mounts; Android's loop does no JS/JSI work
per frame. What the latch cannot do is make a stalled *thread* draw: if the
render server has nothing new to composite because the first draw of the
screen is expensive, that is a content problem, not a transition problem.

**4. Can part of the animation still be lost?** Yes, in one specific sense,
and it is worth being honest about it: **registration is not first paint.**
The latch guarantees the clock starts when a surface exists, not when that
surface is first composited. If the containing screen takes several frames
to present (a modal presentation animation, an expensive first draw), the
transition is running during those frames and the first composited frame
shows it partly advanced. Time-based curves amplify this: an ease-out spends
its fastest travel in the first frames, so even two dropped frames (~33 ms
of a 400 ms curve) can look like a visibly large chunk of missing motion.
Fixing that class of symptom means making the first draw cheaper or
deferring the *content*, not changing the registry.

The taxonomy for "the first frame is already half-expanded":

1. **The clock ran to completion before the surface existed.** The zero-view
   bug. Fixed here.
2. **The clock started at request time; the surface appeared N frames
   later.** Fixed here for the first-mounting host (the rebase measures the
   full duration from the moment a frame can show it). Not fixed for a
   *second* host joining an already-running animation — that join
   deliberately uses the original clock so multiple hosts stay in sync with
   each other.
3. **Frames were dropped after a correctly started clock.** Any wall-clock
   animation recomputes position from elapsed time, so a 100 ms stall snaps
   to 25 % of a 400 ms curve on the next executed frame. This is exactly why
   the driver pushes transitions to CoreAnimation and to a C++ vsync loop
   instead of a JS-runtime timeline; a Reanimated `withTiming` on the same
   screen has no such protection.

**5. Anything else to watch?** If a consumer animates other content on its
own clock (a store's `progress` shared value, say) while the clip animates
natively, those are two clocks with no causal tie. They normally land on the
same frame, but a one-frame offset between clip and content lives there, not
in the registry.

## What Reanimated does differently — and does it validate this design?

Checked against `react-native-reanimated@4.5.0`.

Reanimated's entering animations face the identical problem, because an
`entering` config is created during render, long before the view exists. Its
answer is, structurally, the same latch:

- `AnimatedComponent`'s **constructor** calls `updateLayoutAnimations` with a
  process-global `reanimatedID`, which native stores in
  `LayoutAnimationsManager::enteringAnimationsForNativeID_` — a pending
  animation keyed by an identifier, held until a view exists.
- The component renders that id into the shadow tree as the `nativeID` prop.
- Inside the mounting transaction, the layout-animations proxy (installed as
  the surface's `MountingOverrideDelegate` by `ReanimatedCommitHook`) sees
  the Insert mutation, calls `transferConfigFromNativeID`, re-keys the config
  to the real Fabric tag, and starts the animation there.

So the redemption trigger is the mount mutation itself — the same causal
signal `registerView` is for us, with a different key (`nativeID` vs
`driverId`) and a different interception point (the mutation stream vs the
component's own prop update). That an independent, mature implementation
reached the same shape is the strongest available evidence that latching is
the correct answer rather than a workaround.

Three differences matter:

1. **Reanimated can rewrite the mutation stream; we cannot.** Because it is a
   `MountingOverrideDelegate`, it passes the Insert through and appends an
   `opacity: 0` update in the same transaction so the view is never seen at
   its final state, then restores opacity as the animation progresses. We
   achieve the equivalent by applying the animation's start presentation in
   `registerView` — cheaper, but it only works because our animation's start
   is an explicit value we already hold.
2. **Its per-frame model is the opposite of ours.** Layout animations are
   worklets on the UI runtime driving a `requestAnimationFrame` loop; each
   frame writes into an update map and triggers
   `shadowTree.notifyDelegatesOfUpdates()`, i.e. **a synthesized Fabric
   mounting transaction per animated frame**. That is precisely the
   per-frame cost this library exists to avoid; our transitions are grouped
   `CAAnimation`s in the render tree and one C++ choreographer callback.
   Their model buys generality (any prop, any component); ours buys a fixed
   seven-scalar path with no commit work.
3. **Their pending entry is never collected; ours always completes.** A
   config registered for a component whose view is never inserted stays in
   `enteringAnimationsForNativeID_` (only `transferConfigFromNativeID`
   erases it), and a user-supplied `nativeID` silently loses the animation.
   Our latch is bounded by driver lifetime and always emits exactly one
   completion. Their shipped source also documents the Android-specific
   hazards of starting from a non-main thread — first frames arriving before
   the view is mounted, stuck `opacity: 0`, starts outliving cancellation —
   none of which apply here because the registry is main-thread-only and the
   latch start is synchronous with registration.

### Is the declarative model worth adopting later?

The purest version of the fix is to make the transition part of the commit:
a `transition` prop on `SmoothClipView` carrying target + curve, applied by
the mounting layer, so the race cannot exist by construction. Reanimated's
entering animations are that model.

Pros: no ordering to reason about; the transition travels with the tree that
causes it; no imperative surface to misuse.

Cons, and why it is not planned:

- It does not replace the registry. The reason this library is imperative is
  the gesture path — `setScalars` streaming, mid-flight retargeting,
  interactive→native ownership handoff — none of which fit "declare the
  target at commit time".
- It requires a `MountingOverrideDelegate` or commit hook per surface, which
  is a large amount of platform-specific machinery for a case the latch
  already covers at ~30 lines.
- Adopting their *execution* model would trade away the zero-per-frame
  property. If a declarative entry point is ever added, it should reuse the
  registry's CA / choreographer transitions and only borrow the ordering
  model — declare at commit, start at mount — not the per-frame Fabric
  transactions.

The honest summary: the latch already gives us the ordering guarantee the
declarative model would give us, for the one case (mount-time transitions)
where the two models overlap. Revisit only if a mount-time-only,
zero-imperative API becomes a product requirement of its own.

## Alternatives considered and rejected

- **Consumer-side readiness gate (`onLayout` / `hostReady` state).** Imposes
  ordering by waiting for a causal signal in JS. Correct, but costs 1–3
  idle frames and a render per open, silently depends on the library
  internal that registration precedes layout, and every consumer must
  rediscover it. This is what the app-side workaround did; the latch
  replaces it.
- **A library-exposed attach event / `onHostAttached` promise.** Cleaner
  than the gate but still a main→JS→main round trip before the animation can
  start, and it grows API surface for something consumers should not have to
  think about.
- **Timing heuristics (delay one frame, `requestAnimationFrame` dance).**
  Sometimes too early (bug survives), sometimes too late (idle frames).
  Never correct, only lucky.
- **Full declarative transitions as Fabric props.** See above.

The latch was chosen because it makes the two operations *commute*: whichever
of `animateTo` and `registerView` runs first, the result is identical, and
the component that observes both events synchronously on one thread (the
registry) is the only one that can guarantee that.

## Where the code lives

| Piece | Location |
| --- | --- |
| Latch flag, iOS | `ios/SmoothClipRegistry.mm` — `ActiveAnimation::started`, set in `animateTiming` / `animateSpring` / `animateKeyframes` |
| Latch start, iOS | `ios/SmoothClipRegistry.mm` — `registerView` (`startsLatch` branch), `dispatchActiveAnimationJoin` |
| Latch-aware freeze / replace, iOS | `ios/SmoothClipRegistry.mm` — `canonicalFrozenPresentation`, `resolvedAnimationStart`, guard in `joinActiveAnimation` |
| Per-view deferral (distinct mechanism) | `ios/SmoothClipView.mm` — `_pendingAnimationInstall`, installed in `updateLayoutMetrics` |
| Latch flag + start, Android | `android/src/main/cpp/SmoothClipRegistry.cpp` — `ActiveAnimation::started`, `startAnimation` (`current = start`), `registerViewAndroid` |
| Host-metric re-delivery, Android | `android/src/main/cpp/SmoothClipRegistry.cpp` — `setViewHostGeometryAndroid`, called from `SmoothClipView.onSizeChanged` |
| Tests | `ios/tests/SmoothClipRegistryTests.mm` — latch-until-registration, freeze-at-start, full-duration rebase, latch replacement, destroy-cancels-latch |
| Consumer-facing contract | `README.md`, `onAnimationComplete` section |
