# The Android frame-clock anchor

Why a fast interactive drag handed off to `animateTo` used to hitch on Android
(and never on iOS), what the fix is, and our after-thoughts on whether the
Android architecture should change.

## The symptom

Drag the clip per-frame with `driver.ui.setScalars`, release into
`driver.ui.animateTo` (timing or keyframes). On Android the handoff stuttered —
but only when the drag was fast. Slow drags released smoothly, and iOS was
smooth at any speed.

That velocity dependence was the tell: the engine was losing a fixed amount of
*time* at the handoff, so the on-screen artifact was `drag velocity × lost
time`. Invisible at 200 px/s, a 30–100 px freeze-then-jump at 3000 px/s.

## The defect

Two clocks, one comparison.

`startAnimation` stamped the start with `nowSeconds()` — `steady_clock`, read
mid-frame at the moment `animateTo` ran (typically inside gesture-end
processing). `advance()` then computed

```
fraction = clamp01((now − startedAtS) / durationS)
```

where `now` is the choreographer frame callback's `frameTimeNanos`: the
**vsync timestamp of the frame being produced**, which *precedes* any
mid-frame stamp.
Same `CLOCK_MONOTONIC` timebase, earlier sampling point. First callback:
elapsed ≤ 0, `clamp01` pins the fraction to 0, and the engine re-renders the
value the drag already had on screen. The next callback was often still
near 0. One to two duplicated frames, every handoff, forever — and the deficit
*compounded* with main-thread load at release, which is exactly when an app
does the most work. `advanceSpring` had the same flaw through
`dt = now − lastFrameS` clamped at 0.

Measured on a device (emulator, debug build), logging what the old clock would
have credited on the first frame versus real elapsed time:

| event | old clock credited | real elapsed |
| --- | --- | --- |
| open | 5.6 ms | 24.5 ms |
| fast-drag close | 12.3 ms | **124.2 ms** |
| open (calm frame) | 5.9 ms | 6.1 ms |
| slow-drag snap-back | 15.7 ms | 20.2 ms |

The old clock credits at most ~one vsync no matter how late the first callback
runs. In the 124 ms case it would have replayed the whole 400 ms curve from
~3 % after the stall — the reported jank in one number.

## The fix

`ActiveAnimation.frameClockAnchored`. On the first `advance()` the start stamp
is moved onto the frame-time axis by taking the *earlier* of the two stamps:

```cpp
animation.startedAtS = std::min(animation.startedAtS, now);
animation.lastFrameS = animation.startedAtS;
animation.frameClockAnchored = true;
```

That is not an arbitrary reconciliation — it is precisely the rule Reanimated
uses, so a parallel `withTiming` and the native clip run the *same* curve at
the *same* phase. `valueSetter.ts` stamps an animation's `startTime` with
`global.__frameTimestamp || _getAnimationTimestamp()` and then paces it on
frame stamps, and `min()` reproduces both branches:

- **Call issued between frames** — the common one: `ACTION_UP` is unbatched, so
  a gesture `onEnd` runs outside `doFrame`, where Reanimated's
  `__frameTimestamp` is unset and it takes the wall clock too. The frame that
  dispatches us is later than the call, so the wall stamp survives the `min()`
  and the first fraction is already positive: no duplicated start frame, which
  was the whole point of anchoring. Both engines are then on `(F − W_call)/D`,
  frame for frame — identical up to how precisely each can stamp `W_call`, see
  "What parity actually costs" below.
- **Call issued from inside the frame that dispatches us** — a Reanimated
  mapper or animation callback in the same `CALLBACK_ANIMATION` phase, where
  `__frameTimestamp` *is* this frame's stamp. `min()` adopts the same stamp
  instead of letting `clamp01` pin the fraction to 0. (The narrow variant was a
  start from `CALLBACK_INPUT` — batched moves — where Reanimated still takes
  the wall clock while `min()` adopts the earlier frame stamp, leaving the clip
  ahead by that callback's offset into the frame for the animation's whole
  duration. Closed by the JS-captured stamp — next section.)

What this deliberately is *not* is a wall-elapsed rebase (`startedAtS = now −
(nowSeconds() − startedAtS)`). That is what the anchor originally did, and it
was right for the `AChoreographer` loop this engine used to run on — see "The
second defect" below for why the move to the Java Choreographer retired it.

The spring path gets its first `dt` on the same axis for free.

### Reading the rule instead of approximating it

`min()` reproduces Reanimated's two branches without reading any JS state, and
that indirection had exactly one wrong case: a start issued from an earlier
phase of a frame already in flight (`CALLBACK_INPUT`, batched gesture moves) is
dispatched in that same `doFrame`, whose stamp is *earlier* than the call.
`min()` adopted the frame stamp; Reanimated — outside its rAF flush, where
`__frameTimestamp` is cleared back to `undefined` — kept the wall clock. The
clip led the content by the callback's intra-frame offset for the animation's
whole duration: single-digit milliseconds on a healthy frame, up to a full
frame interval on exactly the heavy transition frame the rest of this document
worries about.

So the issuing worklet now captures the rule's own output at the call site —
`global.__frameTimestamp || global._getAnimationTimestamp()`, the identical
expression `valueSetter.ts` evaluates for a parallel Reanimated animation
started in the same worklet — and hands it through the bindings as an optional
trailing argument (milliseconds; the bindings convert once). Native
`resolveStartStamp()` (`cpp/SmoothClipAnimationCurve.h`, pinned by the
XCTests) adopts it verbatim and marks the animation pre-anchored, so the first
`advance()` skips `min()` entirely. A NaN stamp — stamp-less callers, tests,
iOS ignoring the field — falls back to `nowSeconds()` plus the `min()` anchor:
the approximation remains for the latch flush, which happens native-side long
after any JS stamp went stale, and its two branches are exact there. A stamp
more than a second from the native clock is a broken epoch, not a dispatch
delay, and is rejected the same way.

With the stamp in hand, a `CALLBACK_INPUT` start renders its first frame at
fraction 0 — the same value Reanimated draws on that frame — and every later
frame computes `(F − t0)/D` from the shared t0. What remains is the floor
below, which is Reanimated's own and cannot be closed from this side.

### What parity actually costs

Phase parity is exact up to Reanimated's own timestamp granularity, which is
worth stating because "identical" is what the next person debugging a few
pixels of lead will trust.

`_getAnimationTimestamp()` is `SystemClock.uptimeMillis()`
(`NativeProxy.kt`) — integer milliseconds, truncated. Reanimated's `t0` is
therefore up to 1 ms *earlier* than the true call time while `nowSeconds()`
carries full precision, so on a between-frames start Reanimated leads by up to
1 ms of curve time: ≈0.86 % of total travel at the steepest point of a 350 ms
`Easing.out(Easing.cubic)`, decaying to zero. That is the floor; it cannot be
improved from this side.

Note the sign. Under the wall-elapsed rebase the **clip** led the content by
`L₁` (5–15 ms once the loop moved into `CALLBACK_ANIMATION`). Now **Reanimated**
leads by ≤1 ms — same class of error, opposite direction, an order of magnitude
smaller, and no longer load-dependent.

Per-frame pacing has no such floor: both engines advance on the same
`frameTimeNanos`, which Reanimated takes as a full-precision
`frameTimeNanos / 1e6` (`AnimationFrameQueue.calculateTimestamp`, and
`NodesManager.onAnimationFrame` for its own loop).

Two details are load-bearing:

- **Every `startedAtS` stamp clears the flag.** The re-latch path
  (`unregisterViewAndroid`) rewrites the *same* `ActiveAnimation` in place and
  resumes through `startLatchedAnimation`; without the reset there, the bug
  returns on resume.
- **A `-1` sentinel instead of the bool was rejected** because re-latch reads
  `startedAtS` before the first advance can run — the field must always hold a
  valid timestamp.

Lifecycle re-latching uses `lastFrameS`, updated for timing, keyframes, and
springs on every delivered frame. The frozen presentation, timing cutoff,
keyframe pruning, and residual duration therefore all describe that same
rendered instant; a later detach/unregister wall callback cannot burn an unseen
fraction. The older independent wall-start stamp was removed.

## The second defect: two frame sources on one thread

The anchor fixed the handoff; a subtler pacing defect remained for the whole
duration of every animation. The loop originally ran on the **NDK
`AChoreographer`** — not a handle to the Java `Choreographer` but a *separate*
native instance with its own `DisplayEventReceiver` fd on the main Looper.
Reanimated's prop updates run inside the Java `Choreographer#doFrame` pass, in
`CALLBACK_ANIMATION`, deterministically **before** `CALLBACK_TRAVERSAL`
(measure/layout/draw). The NDK callback had no such ordering: its position
relative to `doFrame` was whatever the Looper's fd poll order gave, and it
could flip frame to frame.

Whenever the clip advance landed *after* the traversal, its write presented
one vsync late (its own invalidation could only schedule the next frame's
traversal). A randomly flipping ±1-frame phase between the clip window and
the content inside it reads as judder for the entire animation — while the
interactive drag path, which writes `setScalars` from inside Reanimated's own
callback, never suffers it. Exactly "drag smooth, animation rough".

The fix moves the loop onto the Java Choreographer through a minimal Kotlin
bridge: `SmoothClipBindings.scheduleFrame` posts a retained
`Choreographer.FrameCallback`, whose `nativeOnFrame` hands `frameTimeNanos`
back to the registry. Plain `postFrameCallback` lands in `CALLBACK_ANIMATION`,
so every advance now runs in the same `doFrame` pass as Reanimated —
deterministically before the draw — and the clip and its content land in the
same frame by construction. The timestamp is the same `CLOCK_MONOTONIC` vsync
stamp the NDK delivered. A side effect retired the 32-bit fallback: Java
delivers `frameTimeNanos` as a `jlong` on every ABI, so the truncation path
(which sampled `nowSeconds()` mid-callback, inheriting dispatch-latency jitter
into the animation's position) is gone.

Moving frame sources also retired the anchor's wall-elapsed rebase and the
run-ahead guard that propped it up, because both were shaped by
`AChoreographer` behavior the Java Choreographer does not have:

- **The stall case is now the platform's job.** The device table above (124 ms
  of real time, 12.3 ms credited) is a stale-vsync artifact: SF delivers the
  one requested vsync, it waits in the socket while the thread is blocked, and
  the NDK dispatcher hands over that original stamp. `Choreographer#doFrame`
  measures the same lateness as `jitterNanos` and **snaps `frameTimeNanos`
  forward** to within one frame interval of now before running any callback.
  It does that once, for every `CALLBACK_ANIMATION` client at the same time —
  so after a stall the clip and the Reanimated content resume at the same
  honest position, together, with no per-engine catch-up logic.
- **Rebasing by wall elapsed became actively harmful.** `startedAtS = now −
  (nowSeconds() − startedAtS)` is algebraically `W_call − L₁`, where `L₁` is
  the *first frame's* intra-frame dispatch latency — a one-time sample that
  shifts the entire curve. Under the NDK loop that ran in the Looper's fd
  phase, `L₁` was sub-millisecond. Posting into `CALLBACK_ANIMATION` puts the
  advance behind RN's dispatcher (Fabric mounts, then Reanimated's batch, FIFO
  by post order), so `L₁` becomes "however much main-thread work ran before us
  on frame one" — sampled on the heaviest frame of a transition and then
  frozen into the phase for its whole duration, leading the content it clips.
- **The run-ahead guard went with it.** Its condition reduces to `L₁ − Lₖ >
  17 ms`; with `L` now equal to main-thread load, "heavy first frame, lighter
  after" — the exact profile of a close — could trip it and snap the clip
  *backwards* mid-flight. Raw `min()` does have the same-doFrame input-phase
  exception described above; worklet-issued starts now bypass it with the
  captured Reanimated stamp. On the remaining fallback/latch path there is no
  persistent run-ahead to correct, and `Choreographer` guarantees frame-stamp
  sanity three separate ways: a vsync stamp arriving
  ahead of `System.nanoTime()` is clamped to it on receipt, `doFrame` bails out
  and re-schedules when `frameTimeNanos < mLastFrameTimeNanos`, and the
  `jitterNanos` correction above only ever moves a stamp *forward*. Frame stamps
  are monotonic and never exceed now, so there is nothing left to guard.

One more property falls out of pacing on the frame stamp, and it is the reason
this is robust rather than merely correct: **an advance's computed position no
longer depends on when inside the frame it runs.** SmoothClip posts a raw
`Choreographer.FrameCallback` while Reanimated arrives behind RN's
`ReactChoreographer` dispatcher; both land in `CALLBACK_ANIMATION`, FIFO by post
order, and which of them runs first can flip between frames. Under the
wall-elapsed rebase that ordering was baked into the curve. Under `min()` both
positions are pure functions of a stamp both engines were handed before either
ran, so the ordering is free to flip and nothing observable changes.

One Kotlin-side non-change is worth recording, because it looks like a gap and
is not: `invalidateOutline()` **does** schedule the redraw. It ends in
`invalidateViewProperty()`, which (hardware-accelerated, display list present)
calls `damageInParent()` → `ViewGroup.onDescendantInvalidated` →
`ViewRootImpl.onDescendantInvalidated` → `scheduleTraversals()`; the
non-accelerated branch calls `invalidate(false)`, also a traversal. Adding a
plain `invalidate()` after it — briefly committed, never released — only sets
`PFLAG_INVALIDATED`, forcing a display-list re-record every changed frame to
restage an outline the RenderNode applies as a property. It was reverted.

## The third defect: keyframes were reconstructed as straight lines

Nothing to do with the clock, but it lands in the same place — the rendered
motion of a close — and it hid behind the same misleading metric.

`interpolateKeyframes` lerped between adjacent keyframes. That is exact *at*
every keyframe, and the position error in between is genuinely tiny (a 31-frame
bake of a 350 ms curve linearizes to well under a pixel). But position error is
the wrong quantity again: straight segments make the interpolated **velocity** a
staircase that steps at every keyframe boundary, beside content whose Reanimated
curve is continuous. Consumers bake dozens of keyframes precisely because their
geometry path is not affine in progress, so reconstructing that path smoothly is
the honest reading of what they asked for.

`KeyframeCurve` (`cpp/SmoothClipAnimationCurve.h`) now evaluates monotone cubic
Hermite (Fritsch-Carlson). Monotone rather than plain Catmull-Rom because these
channels do not tolerate overshoot — width, height and radius must never dip
below zero or bulge past the values the consumer gave. Two keyframes degenerate
to the old straight line: equal in real arithmetic (both tangents equal the
secant), within one ulp — ~1e-13 of the travel, on roughly half of sampled
progress values — in doubles, because the Hermite blend orders its operations
differently than the lerp it replaced. The jfloat delivery cast erases the
difference long before a pixel could see it.

Two things keep it cheap on the hot path. Tangents are solved once in
`reset()`, at animation start and again when the re-latch path prunes the
curve, never per frame — `reset()` pays two small vector allocations for that,
on the start path where a JSI call and a registry lookup already dwarf them.
And the segment scan resumes from the previous frame's index instead of
restarting at 1 — progress is monotonic within an animation, so what used to be
O(keyframes) every frame is now O(1) amortized. The Hermite blend itself costs
a few dozen more flops per frame than the two-op lerp — nanoseconds, beside
the JNI crossing that delivers the result in the same path.

The monotone guarantee is not a promise to preserve an intentionally abrupt
keyframe polyline. Fritsch–Carlson limits neighboring tangents together; with
highly uneven offsets and a sudden change in value density, it can noticeably
round a “crawl, then snap” path while still remaining C¹ and inside every
segment's endpoint range. Author such discontinuous-feeling motion with denser
frames around the transition (or a separate animation); the reconstruction
claim is intended for samples of a smooth underlying path.

**Parity note.** iOS builds a `CAKeyframeAnimation` with `kCAAnimationLinear`
and cannot run this evaluator — CoreAnimation interpolates off-thread, in
another process. The platforms therefore differ mid-segment by exactly the
linearization error this removes: sub-pixel at any realistic keyframe density,
and zero at every keyframe. Closing it needs either `kCAAnimationCubic` (a
different spline, and one that can overshoot — rejected for the reason above) or
resampling the keyframes densely through this curve before handing them to CA.
Left open deliberately rather than papered over.

### Why this math lives in `cpp/`

The anchor, the timing fraction and the keyframe curve moved out of the Android
registry translation unit because that one is bound to fbjni and cannot be
linked into a test binary — which is why the two commits that changed the
animation curve shipped gated on nothing but "it compiles".
`ios/tests/SmoothClipAnimationCurveTests.mm` now pins all three: that the anchor
keeps a between-frames wall stamp and adopts a same-frame stamp, that it can
never lead the frame clock (the reason the run-ahead guard could go), that the
curve passes through every keyframe, never overshoots, stays linear within the
documented one-ulp evaluation difference for two keyframes, tracks the sampled path more closely than straight segments do,
and is C¹ across an interior keyframe. Same arrangement as the shared velocity
tracker: iOS hosts the tests, Android executes the code.

## Why iOS never had this

`animateTo` on iOS commits `CAAnimation`s with `beginTime` resolved at commit,
and the **render server** — a separate process — interpolates them, sampling
each animation at the frame's *target presentation timestamp*, which is already
ahead of the commit. The first composited frame after a release is ~a frame
into the curve by construction; a fraction-0 duplicate frame has no code path
that could produce it. The from-value is read off the live *presentation
layer*, so the start cannot be stale either. And because no per-frame work runs
on the app's main thread, a stall at release delays nothing.

## Why Android is structurally exposed at all

Could a perfectly crafted library have avoided this? Split the answer:

**The clock defect — yes.** It was a bug, it is fixed, and it was subtle for a
reason worth writing down: Choreographer hands you a timestamp from the past.
AOSP's own `ValueAnimator` latches its start at the first frame callback and
renders a fraction-0 frame — the platform's flagship animator ships with a
variant of this exact bug. Post-anchor, this engine handles gesture handoffs
better than the platform's own animator does.

**The main-thread ticking — no.** The library animates an arbitrary view clip
(outline rect + radius + content translate). Android has no public
render-server animation for that: RenderThread drives only a small fixed
property set (how ripples and `createCircularReveal` stay smooth), and
`RenderNodeAnimator` is hidden API — an animated `Outline` is not in the set
regardless. Anything animating an arbitrary clip must tick per frame on the
main thread via Choreographer. `ValueAnimator`, Reanimated, and React Native's
native Animated driver all live under the same constraint. This is the
platform's shape, not a design shortcut.

## Residual structural exposures, ranked honestly

1. **A main-thread stall drops animation frames — irreducible.** iOS renders
   through stalls; Android cannot, for this class of animation. The anchor
   changed the failure mode from "freeze, then replay the curve from zero"
   (time lost) to "freeze, then land at the honest position" (time preserved,
   CoreAnimation-equivalent semantics), and since the loop moved onto the Java
   Choreographer that catch-up is the platform's `jitterNanos` correction
   rather than ours — which means the clip and any parallel Reanimated
   animation resume at the same position, together. Nothing can paint pixels
   while the thread is blocked; app-level stalls are the remaining jank budget
   on Android.
2. **Integer outline quantization — platform-forced, and the cost is temporal,
   not spatial.** `Outline.setRoundRect` takes an int rect (float `setPath`
   outlines cannot clip), so motion quantizes to whole pixels and sub-pixel
   frames are skipped. iOS animates floats.

   The 0.5 px spatial bound is the reassuring number and the wrong one. What
   reads as jank is the per-frame *derivative*: a static half-pixel bias is
   invisible, an error that alternates between frames is not. During a drag the
   per-frame delta is tens of pixels and quantization disappears under it; on an
   ease-out tail the delta falls below a pixel and the quantization *is* the
   motion — which is why an animation can feel rougher than the gesture that
   launched it even when both are perfectly paced.

   Both oscillating terms have been removed, in two steps that depend on each
   other:

   - **Size.** Rounding both edges independently made `round(right) −
     round(left)` alternate between the floor and the ceil of a *constant*
     extent as the origin's fraction swept, so pure translation breathed the
     emitted size by 1 px every frame while the content inside translated in
     floats. `outlineFarEdge` derives the far edge from the rounded origin plus
     the rounded extent, making the emitted size a pure function of the true
     size. An int rect cannot bound origin, far edge and extent at half a pixel
     simultaneously — extent is their difference — so the slack moved onto the
     far edge, where it is ≤1 px and *static*.
   - **Position.** The rounded origin still snapped to the pixel grid, so the
     clip-to-content offset kept jittering even with the size held. The
     remainder (`left − round(left)`) is now carried on the view's own
     `translationX/Y` and subtracted back out of the content container, so the
     clip edge lands where the driver asked and the content does not move with
     it. This is only expressible because the far edges are derived: with
     independently rounded edges the rect had two independent errors per axis
     and no single translation could place both.

     That property is shared with the consumer's `transform` prop, so
     `SmoothClipView` overrides `setTranslationX/Y` and composes the two rather
     than letting either win — RN routes every transform write through those
     setters (`BaseViewManager.setTransformProperty`). Hit testing adds the
     residual back to the incoming point, so it still tests the geometry the
     driver delivered.

   - **Emptiness.** `Outline.setRoundRect(Int...)` collapses a degenerate
     emitted rect to an empty outline. The view now derives `clipIsEmpty` from
     those same rounded integer edges, not from the pre-rounding floats, and
     uses it consistently for visibility, accessibility and hit testing. A
     positive extent below 0.5 px is therefore empty; 0.5 px rounds to a
     visible 1 px outline. Because emptiness is a pure function of the emitted
     edges, it cannot flip while the existing outline-dedupe key stays equal,
     so `invalidateOutline()` cannot miss the transition.

     This is a deliberate sub-pixel divergence from iOS, which masks in floats
     and calls only a zero-or-negative extent empty (`CGRectIsEmpty`). Both
     platforms make the semantic state — hidden, out of the accessibility tree,
     not accepting touches — agree with what they actually render, and that
     agreement is the invariant worth holding identical; the exact threshold
     cannot be, because one platform quantizes the outline and the other does
     not. Consequence for a consumer: a clip animating through `(0, 0.5)` px
     goes non-interactive one frame earlier on Android.

   What remains is the ≤0.5 px static size bias, which does not alternate and so
   does not read as motion.
3. **Per-frame cost — near the floor.** Integrate 7 scalars, normalize, one JNI
   call, four property stores (two of them self-deduping no-ops when only the
   outline moved), `invalidateOutline` only on frames whose *rounded* rect
   actually changed. Allocation-free, no layout. Sub-pixel-only frames now cost
   a translation write where they used to cost nothing and render nothing —
   that is the fix having a price, not a regression.
4. **One structural advantage over iOS.** Consumers often run Reanimated
   content animations in parallel with the native clip. On Android the two are
   coherent in both dimensions that matter: they advance in the same
   `Choreographer#doFrame` animation phase (same *frame*), and they stamp `t0`
   by the same rule and pace on the same frame stamps (same *phase*). They
   stall together and catch up together — by construction, not by luck. On iOS
   a main-thread stall lets CA keep moving the clip while Reanimated's content
   freezes — a desync Android cannot have.

## Options considered and rejected

- **SurfaceControl-based clip layer** (`Transaction.setCrop` /
  `setCornerRadius` / `setPosition` applied off-main, composited by
  SurfaceFlinger — how PIP and app transitions survive stalls). The content
  would have to render into that surface, breaking the composition model
  (z-order, input routing, sibling synchronization). A rewrite with worse
  ergonomics to mitigate a stall class that is app-caused anyway.
- **Catch-up clamping** (cap the post-stall jump for continuity). Diverges
  from CoreAnimation semantics and makes the platforms feel different — and
  it would now also de-phase the clip from a parallel Reanimated animation,
  which takes the platform's uncapped catch-up. Revisit only if a
  teleport-after-stall ever reads badly on hardware.
- **`postVsyncCallback` frame timelines** (API 33+). Marginal pacing
  refinement, not worth the API gating today.

## Consumer-side corollary

The engine starts a handoff animation from its own `latest` value, but a
keyframes animation interpolates its supplied frames *absolutely* — so frame 0
should equal what is actually on screen. Two gesture-runtime details make that
easy to get subtly wrong on Android: `ACTION_UP` carries a fresher position
than the last `onUpdate`, and a same-batch final `onUpdate` may never flush
through a gated `useAnimatedReaction`. The robust release pattern is one call:
adopt the release sample in `onEnd` and pass it as `animation.from` to
`animateTo` — internally a fused `setScalars` take-ownership hot write — making
rendered value, native start, and keyframe 0 identical by construction. (The
explicit two-call form, `setScalars(...)` then `animateTo(...)`, remains valid
and is exactly what `from` desugars to.)

The native velocity tracker makes this pattern safe with
`initialVelocity: 'inherit'` as well: a release-sample seed recorded in the
same frame as the last drag write **coalesces** into one observation, and an
**identical** seed is deduplicated (keeping the last real motion aging through
the 100 ms staleness guard), so the inherited velocity stays honest instead of
zeroing (dead spring) or dividing sub-frame displacement by microseconds
(wild overshoot). The logic is shared verbatim by both platforms in
`cpp/SmoothClipVelocityTracker.h`.

## Does 0.2.3 affect iOS?

The two changes have different blast radii, both deliberate:

- **The frame-time anchor does not touch iOS at all.** It lives entirely in
  `android/src/main/cpp/SmoothClipRegistry.cpp`; no file under `ios/` changed,
  and the defect it fixes is structurally impossible there (the render server
  interpolates committed CAAnimations — there is no first-frame fraction to
  compute, so there is nothing to anchor). iOS pixels in 0.2.3 are
  bit-identical to 0.2.2 for existing code.
- **`animation.from` is available on iOS and safe to adopt** — it is
  driver-layer TypeScript shared by both platforms, desugaring to the same
  take-ownership hot write everywhere. On iOS the seed stops any running
  Core Animation and writes the model layer, so `from` re-grabs a running
  transition on iOS exactly as it does on Android. One nuance, unchanged
  from the two-call pattern it replaces: **keyframes start exactly at
  `from`** (frame 0 travels in-band as the CAKeyframeAnimation's first
  value), while **timing/spring source their CA from-value from the
  presentation layer** (`smoothClipCurrentPresentation`), i.e. the last
  committed frame — at most one frame behind `from`. This is intended
  behavior, not a pending refinement: the presentation layer is what the eye
  last saw, so sourcing the CA from-value there is the visually continuous
  choice — an "exact `from`" would start the transition from a value that
  never rendered, reintroducing a one-frame discontinuity to fix a skew no
  one can see.

In short: iOS needs neither fix — the anchor's bug cannot occur there, and
the fresher-release-sample gap `from` closes is an order of magnitude smaller
on iOS — but `from` is cross-platform by design so one release code path
serves both, and adopting it on iOS is strictly neutral-to-better.
