# Content scale presentation channel

## Status

Proposed and feasible, but deferred.

If implemented, `contentScale` should be a full presentation channel on iOS
and Android. An iOS-only public channel is not an acceptable endpoint.

## Motivation

The native presentation currently contains seven scalars:

- clip x, y, width, height, and radius;
- content translation x and y.

`ZoomOverlay` needs one additional value: a uniform content scale. It currently
applies that value with a Reanimated style on a view nested inside
`SmoothClipView` (`example/src/components/ZoomOverlay.tsx`).

That creates two animation clocks on iOS. A native `animateTo` installs Core
Animation objects, so the render server continues moving the clip during a
main-thread block. The nested Reanimated scale runs on the main thread and
freezes. If a block overlaps a post-drag snap-back or close, the clip window
moves while its content zoom stalls.

Android does not show the same split during a block because both the native
registry frame loop and Reanimated view updates require the main thread. All
channels stall together. Android support still matters: presentation values
must have one meaning across platforms, and making scale native removes the
extra per-frame Reanimated style there as well.

The affected interval in the example is narrow. Opening has scale `1`; scale
changes only after a dismiss drag, during the 250 ms snap-back or 400 ms close.
The desynchronization therefore requires both a scale-changing transition and
an overlapping main-thread stall. It is visible when forced, but it is not a
general animation failure.

## iOS feasibility

`SmoothClipView` owns a host-sized `_contentContainer` whose layer is centered
inside the clip container. Content translation is written as that layer's
affine transform and animated with `transform.translation.x` and
`transform.translation.y` in a content `CAAnimationGroup`
(`ios/SmoothClipView.mm`). Timing, spring, and keyframe paths all install that
group beside the geometry group.

A `transform.scale` animation in the same content group would be evaluated by
Core Animation after commit. It would continue through a main-thread block in
the same way as the existing clip geometry and content translation tracks.

The transform must preserve the existing visual order:

1. scale uniformly around the content container's center;
2. apply content translation without multiplying it by the scale.

The model transform should therefore contain uniform `a`/`d` scale components
and independent `tx`/`ty` translation components. Concatenating transforms in
the wrong order would scale the translation compensation and make the content
drift relative to the clip.

Scale cannot be animation-only state. These paths must all read or write it:

- requested and normalized presentation storage;
- presentation-layer sampling;
- `beginInteraction` and cancel-to-current;
- freeze, background, detach, and zero-size relatching;
- relayout animation rebuilds;
- late host joins and initial presentation replay.

Otherwise an interruption would freeze the clip and translation correctly but
reset content scale to `1`.

## Android design

Android should receive the same eighth presentation scalar. The C++ registry
would deliver it with clip geometry and content translation, and
`SmoothClipView` would write it to both `contentContainer.scaleX` and
`contentContainer.scaleY`.

The default Android pivot is the view center, matching the centered iOS layer
and the current full-screen React Native child. Tests should still set or
assert the pivot contract explicitly so a later layout change cannot move the
zoom origin unnoticed.

Android carries the rounded clip origin's sub-pixel residual on the outer view
and subtracts it from the content translation. Scale must remain an independent
view property:

```text
outer translation = consumer translation + clip residual
content translation = requested content translation - clip residual
content scale = requested content scale
```

Scaling the content translation matrix itself would turn one pixel of residual
correction into `scale` pixels and reintroduce clip/content drift.

Scale-only updates must also be applied before the geometry-only
`outlineChanged` early return. Scale does not affect the outline cache, but an
unchanged outline must not suppress a changed content transform.

### Spring units

The Android spring integrator currently applies shared settle thresholds to
seven DIP-valued channels: `0.05` DIP displacement and `1` DIP/s velocity.
Scale is dimensionless and normally near `1`. Reusing those thresholds would
allow a spring to finish with a 5% scale error or while moving at one complete
scale unit per second, followed by a visible snap.

Scale needs its own displacement and velocity tolerances. The existing DIP
thresholds should stay unchanged for clip and translation channels.

### Inherited velocity

`initialVelocity: 'inherit'` projects recent interactive movement onto the
remaining seven-channel trajectory. Adding a raw scale component to that dot
product would mix hundreds of DIP with values around `1`, giving scale an
arbitrary and usually negligible weight.

Keep the inheritance projection seven-dimensional and explicitly exclude
scale. Use the resulting normalized trajectory velocity to seed each spring
channel, including scale:

```text
scale velocity = inherited scalar * (target scale - start scale)
```

This preserves existing handoff behavior and keeps scale in phase with the
other spring channels. A scale-only inherited spring starts with zero inherited
velocity rather than inventing a conversion between scale and DIP.

## Public model and wire format

The public presentation can add an optional source field:

```ts
type SmoothClipPresentation = Readonly<{
  clip: ClipGeometry;
  contentTranslateX: number;
  contentTranslateY: number;
  contentScale?: number;
}>;
```

JS should canonicalize missing scale to `1` immediately. Native and internal
presentation values should always contain a finite, strictly positive scale.
Equality, validation, interpolation, keyframes, direct commands, and initial
props must use the canonical value.

The existing positional native methods cannot be widened safely in place:

- Android already reads an optional `recordVelocity` after
  `setClipPresentation`'s declared arguments.
- Android already reads an optional frame-clock timestamp after every
  animation method's declared arguments.
- iOS codegen reads declared parameters positionally, rejects missing declared
  arguments, and ignores current trailing Android-only arguments.

Inserting scale before those trailing values makes new native code misread old
JS values. Appending it after them prevents the current iOS TurboModule from
seeing it. Changing the codegen declarations also makes old JS incompatible
with new native code that requires the additional positions.

A compatibility-preserving release should add versioned methods, for example:

- `setClipPresentationWithScale`;
- `animateTimingWithScale`;
- `animateSpringWithScale`;
- `animateKeyframesWithScale`.

The new methods can use a natural eight-channel layout. Flat keyframes become
stride 9: offset plus eight presentation values. Capability detection selects
the new family; the legacy family remains available with scale fixed at `1`.
Presentation arrays returned by begin/cancel can grow from seven to eight
values because new JS can default a shorter old-native result to `1` and old JS
ignores extra array entries.

## Alternatives

### iOS-only native scale

Rejected. It would give the same public presentation different behavior on
iOS and Android, preserve the extra Reanimated transform on Android, and still
require most of the difficult iOS state and compatibility work.

### Animate content width and height

Rejected. Resizing a container does not scale descendant pixels equivalently,
changes layout and hit-testing semantics, and cannot reproduce the current
center-pivot transform without additional compensation.

### Keep the current split

Reasonable for now. The mismatch appears only when a main-thread stall overlaps
a short scale-changing transition. The measured `setScalars` path is already
about 7 microseconds, so removing one small Reanimated style is not by itself a
performance reason to expand the presentation protocol.

## Test surface

An implementation should be pinned by:

- XCTest coverage for timing, spring, and keyframe scale animations; model and
  presentation reads; freeze, cancel, relatch, relayout, and late joins;
- an iOS stress test that blocks the main thread during a scale-changing
  animation and verifies clip, translation, and scale remain phase-locked;
- shared C++ tests for eight-channel interpolation/keyframes, unchanged
  seven-channel velocity projection, and scale-specific spring settling;
- Robolectric tests for centered uniform scale, scale-only updates, residual
  translation composition, resize behavior, and existing touch semantics;
- Jest tests for default `1`, validation, equality, new method arities,
  result-array fallback, and keyframe stride 9;
- manual ZoomOverlay snap-back and close checks on both platforms. iOS should
  continue all channels through a block; Android should stall and recover all
  channels together without a pivot or residual jump.

## Recommendation

Do not add an iOS-only or animation-only scale track. Defer the feature until
render-server coherence for scaled content is an explicit library requirement.
When that requirement exists, implement one versioned, cross-platform eighth
presentation channel with Android-specific spring tolerances and the existing
seven-dimensional inherited-velocity projection.
