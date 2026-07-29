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

where `now` is the AChoreographer callback's `frameTimeNanos`: the **vsync
timestamp of the frame being produced**, which *precedes* any mid-frame stamp.
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

`ActiveAnimation.frameClockAnchored`. On the first `advance()`, the wall-clock
start stamp is translated onto the choreographer frame-time axis, preserving
real elapsed time:

```cpp
const double wallElapsedS = std::max(0.0, nowSeconds() - animation.startedAtS);
animation.startedAtS = now - wallElapsedS;
animation.lastFrameS = animation.startedAtS;
animation.frameClockAnchored = true;
```

The first rendered frame advances by honest elapsed time; later frames pace on
the vsync axis. The spring path gets a correct first `dt` for free, and on the
32-bit fallback (where `now` is already `nowSeconds()`) the anchor is ~identity.

Two details are load-bearing:

- **Every `startedAtS` stamp clears the flag.** The re-latch path
  (`unregisterViewAndroid`) rewrites the *same* `ActiveAnimation` in place and
  resumes through `startLatchedAnimation`; without the reset there, the bug
  returns on resume.
- **A `-1` sentinel instead of the bool was rejected** because re-latch reads
  `startedAtS` before the first advance can run — the field must always hold a
  valid timestamp.

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
   CoreAnimation-equivalent semantics). Nothing can paint pixels while the
   thread is blocked; app-level stalls are the remaining jank budget on
   Android. A **run-ahead guard** completes the semantics: the anchor's
   one-time shift bakes the first callback's dispatch latency into the frame
   axis, and if later choreographer stamps catch up to real time the
   animation would lead wall time by that latency and complete early —
   `advance()` re-anchors forward whenever frame-axis elapsed exceeds wall
   elapsed by more than one vsync of slack (`kMaxFrameLeadS`). The condition
   is unreachable on calm frames (it requires the first callback to have run
   more than a vsync later, relative to its stamp, than the current one), so
   the hot path is unchanged.
2. **Integer outline quantization — platform-forced, negligible.**
   `Outline.setRoundRect` takes an int rect (float `setPath` outlines cannot
   clip), so motion quantizes to whole pixels and sub-pixel frames are skipped.
   Max error 0.5 px; iOS animates floats.
3. **Per-frame cost — already at the floor.** Integrate 7 scalars, normalize,
   one JNI call, two property stores, `invalidateOutline`. Allocation-free, no
   layout.
4. **One structural advantage over iOS.** Consumers often run Reanimated
   content animations in parallel with the native clip. On Android both tick
   on the same thread and clock family: they stall together and catch up
   together, staying coherent. On iOS a main-thread stall lets CA keep moving
   the clip while Reanimated's content freezes — a desync Android cannot have.

## Options considered and rejected

- **SurfaceControl-based clip layer** (`Transaction.setCrop` /
  `setCornerRadius` / `setPosition` applied off-main, composited by
  SurfaceFlinger — how PIP and app transitions survive stalls). The content
  would have to render into that surface, breaking the composition model
  (z-order, input routing, sibling synchronization). A rewrite with worse
  ergonomics to mitigate a stall class that is app-caused anyway.
- **Catch-up clamping** (cap the post-stall jump for continuity). Diverges
  from CoreAnimation semantics and makes the platforms feel different.
  Revisit only if a teleport-after-stall ever reads badly on hardware. (The
  run-ahead guard above is a different thing: it never caps the honest
  catch-up frame — it only stops the frame axis from *leading* wall time on
  the frames after it.)
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
