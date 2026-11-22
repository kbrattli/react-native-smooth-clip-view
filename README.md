# react-native-smooth-clip-view

Layout-free animated rounded clipping for React Native Fabric.

`SmoothClipView` is a fixed viewport. Its controller moves a rounded aperture
inside that viewport using raw host-local coordinates. Content is clipped by the
aperture, an optional outset shadow may extend outside the aperture, and the host
finally crops both. A full-screen host therefore accepts screen coordinates
directly, including negative and off-screen frames.

Use this library when a transition needs streamed gesture updates followed by
native-owned timing or spring motion without animating Yoga layout. A regular
Reanimated `View` with `overflow: 'hidden'` remains the simpler choice when
layout-thread work and interruption snapshots are not concerns.

## Demo

https://github.com/user-attachments/assets/899235b3-de69-46d7-b6db-61bc54d80df8

## Requirements

- React Native 0.86 or newer with the New Architecture
- React 19.2 or newer
- React Native Reanimated 4.5 or newer
- React Native Worklets 0.10.1 or newer
- Android API 24 or newer

```sh
npm install react-native-smooth-clip-view react-native-reanimated react-native-worklets
cd ios && pod install
```

## One clip

```tsx
import {
  ClipEasings,
  SmoothClipView,
  useSmoothClipController,
} from 'react-native-smooth-clip-view';

function Reveal() {
  const clip = useSmoothClipController({
    clip: { x: 24, y: 80, width: 96, height: 96, radius: 24 },
    contentTranslateX: -24,
    contentTranslateY: -80,
    contentScale: 1,
  });

  const open = () => {
    clip.react.animateTo(
      {
        clip: { x: 0, y: 0, width: 390, height: 844, radius: 0 },
        contentTranslateX: 0,
        contentTranslateY: 0,
        contentScale: 1,
      },
      {
        type: 'timing',
        duration: 400,
        controlPoints: ClipEasings.easeOutCubic,
      }
    );
  };

  return (
    <SmoothClipView controller={clip} style={{ flex: 1 }}>
      {/* screen-sized transition content */}
    </SmoothClipView>
  );
}
```

One controller may have one mounted host at a time. Sequential unmount and
remount is supported. In development, mounting the same controller in two hosts
throws an error.

## Worklet API

Call `clip.ui` methods from a UI-runtime worklet:

```ts
clip.ui.setFrame(presentation);

const run = clip.ui.animateTo(target, spring, 1);

clip.ui.cancel(run); // optional; freezes at the visible frame
```

These calls, and `group.ui`'s, must run on the UI thread: in `scheduleOnUI`, a
gesture or frame callback, or an animated reaction. `runOnUISync` runs its
worklet on the calling JS thread, where native cannot reach the host. There,
`beginInteraction`, `setFrame`, `animateTo` and `cancel` throw an error that says
so, and `isReady()` reports `false`.

Native terminal events are delivered on the React JavaScript runtime through
one stable controller callback. Consumer callbacks are never retained in the
UI runtime:

```ts
const clip = useSmoothClipController(initialPresentation, {
  onAnimationComplete(result) {
    // result.completionTag is 1 for the tagged run above
    // result.finished is true only when the target was reached
  },
});
```

The optional completion tag is a nonnegative 32-bit integer. Use it to identify
UI-runtime runs without retaining a consumer worklet for the animation lifetime.

`setFrame` canonicalizes the object in the worklet and makes one scalar JSI call.
It does not update React state, animated props, Yoga, the ShadowTree, or a public
SharedValue.

`beginInteraction()` atomically interrupts native motion and returns
its visible raw presentation. Apply the final gesture sample with `setFrame()`
before calling it when the release must start from that exact frame.

`isReady()` reads whether the mounted host is on screen: it has a non-zero layout
and is attached to a visible window, and on iOS its layer has been committed.
Poll it from UI frames to start a transition only once the host shows. Unlike
`onLayout` and `measure`, which report the shadow tree, it cannot hold before the
native mount.

## React API

React-thread animation starts synchronously return a run object:

```ts
const run = clip.react.animateTo(target, {
  type: 'spring',
  stiffness: 180,
  damping: 22,
  velocity: 1.4,
});

// run.cancel(); // optional; freezes the visible frame and resolves false
const finished = await run.finished;
```

Timing accepts `duration` and cubic-Bezier `controlPoints`. Spring accepts
optional `mass`, `stiffness`, `damping`, normalized `velocity`, and
`energyThreshold`. Both specifications accept `reduceMotion`. The physical
defaults match Reanimated 4.5: mass `4`, stiffness `900`, damping `120`, and
relative energy threshold `6e-9`. A spring is rejected when its resolved native
trajectory could make `contentScale` nonpositive.

`velocity` is a shared initial progress velocity in inverse seconds, defaulting
to `0`. Each changing channel starts with velocity proportional to its remaining
distance: `velocity * (target - start)`. This includes rotation (in radians) and
opacity. A spring never inherits motion on its own: starting one after
`beginInteraction()`, or over a moving run, starts from rest unless `velocity`
says otherwise. Pausing and resuming an existing native spring preserves its
internal motion state; public snapshots return clamped opacity.

`velocity: 'inherit'` takes the velocity the clip is moving with when the
spring starts, resolved natively for each clip of the call:

- over a moving run (a retarget), the replaced run's own velocity at the
  moment it is replaced, timing or spring;
- after `beginInteraction()`, the velocity of the frames the interaction
  streamed through `setFrame` (a gesture release);
- otherwise `0`.

The velocity is projected onto the new run's own displacement, using clip
position, size, corner radii, and content translation. Rotation, opacity,
content scale, and shadow channels do not contribute to that projection, so
rotation/opacity-only motion supplies no inherited velocity. The resulting
normalized velocity drives all changing channels.

```ts
// Retarget a run mid-flight without a kink in its speed.
clip.ui.animateTo(actual, { type: 'spring', velocity: 'inherit' });

// Release a drag: continue the finger's velocity into the spring.
clip.ui.animateTo(rest, { type: 'spring', velocity: 'inherit' });
```

A run that replaces a moving run starts from the frame the clip shows when the
call is made, and its clock starts then too, so the motion continues in the
next frame drawn.

An animation requested before the host has a positive layout waits, then starts
with its full duration. While the application is inactive, native animation
transactions stay pending and do not report cancellation. Timing animations
retain wall-clock progress and catch up after activation. Springs stay frozen;
their first foreground step consumes at most 64 ms, matching Reanimated, and
then they continue normally. If the platform discarded an underlying animation
object, the transaction settles successfully at its requested target.

Interactive `setFrame()` updates remain application-owned. The library does not
reset a drag or mutate related SharedValues or React state when lifecycle state
changes, so applications do not need lifecycle integration for the clip itself.

Host loss while the application is active keeps the existing semantics:
standalone animations apply their target and finish successfully, while groups
(including public controllers because they use one-member groups) freeze every
member and resolve `false`. Replacement, cancellation, destruction, and
rejection also settle once with `false`.

## Atomic groups

Store `controller.ref` when multiple clips must update or settle atomically:

```ts
const group = useSmoothClipGroup();

group.ui.setFrames([
  { clip: first.ref, frame: firstFrame },
  { clip: second.ref, frame: secondFrame },
]);

const snapshots = group.ui.beginInteraction([first.ref, second.ref]);

const run = group.react.animateTo(
  [
    { clip: first.ref, target: firstTarget },
    { clip: second.ref, target: secondTarget },
  ],
  { type: 'timing', duration: 320, controlPoints: ClipEasings.easeOutCubic }
);

const result = await run.finished;
```

`group.ui.setFrames` uses one native batch call. `beginInteraction` snapshots and
cancel snapshots preserve input order and report whether each clip currently has
a displayable host. Controllers are implemented as one-member groups, so both
APIs share validation, run ownership, and completion behavior.

## Flights (hero transitions)

A host with `flight` leaves its screen while it runs: its content flies in a
window-level layer above navigation transitions and sheets, and comes back when
the run ends. A `SmoothClipFlightTarget` with the same tag is the other
endpoint: it is hidden while the flight is airborne and revealed in the frame
the flight lands on it. Nothing is snapshotted or re-rendered: the host's own
views move into the layer and back, on iOS and Android.

```tsx
import {
  SmoothClipFlightTarget,
  SmoothClipView,
} from 'react-native-smooth-clip-view';

// The list: the card is the flying host.
<SmoothClipView
  controller={clip}
  flight={`photo-${photo.id}`}
  style={styles.card}
>
  {/* laid out at the destination size; cropped into the card by the clip */}
  <Image source={thumb} style={detailSize} />
</SmoothClipView>;

// The pushed route: the hero is the target.
<SmoothClipFlightTarget tag={`photo-${id}`} ready={loaded} style={styles.hero}>
  <Image source={fullRes} onLoad={() => setLoaded(true)} style={styles.fill} />
</SmoothClipFlightTarget>;
```

### API

- **`SmoothClipView` `flight?: string | true`.** Every run on the host lifts it
  into the flight layer. A string pairs it with the target of that tag; `true`
  flies with no target (the host comes back when the run ends).
- **`SmoothClipFlightTarget`** (`ViewProps` plus `tag` and `ready`). Its
  children are hidden natively, without touching their React styles, from the
  frame a flight with its tag lifts, or the frame the target mounts while one
  is airborne, whichever is later.
  - **`ready?: boolean`** (default `true`). While `false`, a flight that has
    arrived keeps its own content on screen at the destination instead of
    revealing the target, for example until a full-resolution image has loaded.
    Setting it to `true` reveals the target in the next frame.
- **`space: 'window'`** on a presentation. The clip, content translation and
  shadow are in window coordinates, as if the host sat unscaled at the window
  origin. Native converts them through the host's transform to the window when
  the run starts (or the frame is set), so a flight targets a window rect
  without `measure()`, and a host under a scaled or translated ancestor still
  lands exactly on it. Accepted by `animateTo` targets and `setFrame`; an
  initial frame is always host space. A transform that rotates, skews or
  scales unevenly rejects the call. On Android the window is the React root's
  area, as for layout and `measureInWindow`: without edge-to-edge it starts
  below the status bar.
- **`velocity: 'inherit'`** on springs, for retargets and releases (see the
  React API above).

### What a flight does

1. **Lift.** When a run installs, or on `beginInteraction()`, the host's
   content moves into the window's flight layer, drawn through the host's
   transform at that moment, so the first frame does not jump. The target is
   hidden.
2. **Direction.** If the target was on screen when the host lifted, the flight
   _departs_ from it (the way back, or a route-hosted hero leaving its card) and
   never hands off to it. Otherwise it _lands on_ it.
3. **Handoff.** When a landing flight's run finishes and its target is
   attached, `ready` and out of any screen transition, one native transaction
   reveals the target, moves the content back into the host and resets the host
   to the frame it started from. The completion callback reports that rest
   frame. A target that is mounted but not yet attached (a screen the navigator
   is about to show) is waited for up to 300 ms; a target that is not `ready`
   or is mid-transition is waited for as long as it takes, with the flight
   holding its final frame.
4. **Return.** A departing flight, or one with no target, moves the content
   back when the run ends and the host is on screen. A host whose screen is
   detached gets it back after 300 ms anyway. A landing flight whose target
   went away mid-flight (its route was popped and nothing flew the host home)
   comes back at the frame it started from, not at the destination. Start a
   run home in your back handler for a smooth return.
5. **The way back.** A later run on a host that handed off, while that target
   is still on screen, starts from the frame it landed on, so closing is
   `clip.react.animateTo(rest, spring)` with no `from`.
6. **Interrupted runs.** A run that is cancelled never hands off. A run that
   replaces another, an interaction, or `setFrame` continues the same lift; an
   interaction holds the lift until the next run ends. End an interaction with
   a run. One that departed from a target that then unmounts (a route that
   follows its own dismissal, popped from JavaScript) lands on its own, with the
   host back at rest.
7. **Host loss.** If the host unmounts mid-flight, or its controller is
   destroyed, the flight finishes on its own and reveals the target.

Reduced-motion runs do not lift: they jump in place. `isReady()` is true once
the host can enter the flight layer.

### Recipes

**Source flight from a gesture.** Start the run in the UI-thread callback, in
window space, then navigate. The run is native from the first frame, so a
heavy destination route or a busy JS thread does not delay it.

```tsx
const tap = Gesture.Tap().onEnd((_e, ok) => {
  'worklet';
  if (!ok) return;
  clip.ui.animateTo({ ...detailPresentation, space: 'window' }, SPRING);
  scheduleOnRN(router.push, `/photo/${photo.id}`);
});

// Back: fly home from the target (the way back), then pop.
const back = () => {
  cardClip.react.animateTo(cardRest, SPRING);
  router.back();
};
```

**A hero hosted in the route.** The list item is the target; the route's host
starts on the card's window rect and opens on mount. It starts with the
navigation commit, so it is slower than a source flight.

```tsx
const clip = useSmoothClipController(cardPresentationInHost);
useEffect(() => {
  clip.react.animateTo(detailPresentation, SPRING);
}, []);
<SmoothClipView controller={clip} flight={`photo-${id}`}>
  {hero}
</SmoothClipView>;

// The list:
<SmoothClipFlightTarget tag={`photo-${id}`}>
  {thumbnail}
</SmoothClipFlightTarget>;
```

**A destination rect known late.** Fly towards a prediction, and retarget when
the destination is laid out; inherit keeps the speed continuous.

```ts
clip.ui.animateTo({ ...predicted, space: 'window' }, SPRING);
// later, from a worklet:
clip.ui.animateTo(
  { ...actual, space: 'window' },
  { type: 'spring', velocity: 'inherit' }
);
```

**Drag to dismiss.** `beginInteraction()` lifts the host, `setFrame` follows
the finger, and the release continues the finger's velocity.

```ts
const pan = Gesture.Pan()
  .onStart(() => {
    'worklet';
    clip.ui.beginInteraction();
  })
  .onUpdate((e) => {
    'worklet';
    clip.ui.setFrame(dragFrame(e));
  })
  .onEnd((e) => {
    'worklet';
    clip.ui.animateTo(e.velocityY > 800 ? rest : landed, {
      type: 'spring',
      velocity: 'inherit',
    });
  });
```

**Swipe-back on iOS.** react-native-screens reports a screen's transition
progress on the UI thread. Wrap the navigator in `ReanimatedScreenProvider`
(from `react-native-screens/reanimated`), keep the native stack's default
animation and `gestureEnabled`, and follow the progress of the screen the pop
returns to:

```tsx
const { progress, closing, goingForward } = useReanimatedTransitionProgress();
const following = useSharedValue(false);
useAnimatedReaction(
  () => ({
    p: progress.get(),
    closing: closing.get(),
    forward: goingForward.get(),
  }),
  ({ p, closing, forward }) => {
    if (closing || forward) return; // only a pop back to this screen
    if (!following.get()) {
      if (p >= 1) return;
      following.set(true);
      clip.ui.beginInteraction(); // lifts from the landed frame; hides the target
    }
    clip.ui.setFrame(mix(landed, rest, p)); // window space
    if (p >= 1) {
      following.set(false);
      clip.ui.animateTo(rest, SHORT_TIMING); // ends the interaction: it lands
    }
  }
);
```

- UIKit's finish and cancel animations keep reporting progress after the
  finger lifts, so the host arrives at rest and needs no release velocity. End
  the interaction with a short run: a flight lands when its run ends, and a
  spring's run lasts its whole settling time (about 0.8 s for the default).
- A cancelled swipe reports no final progress. Listen for the navigator's
  `gestureCancel` event on the popped screen and run back to `landed`.
- Popping from JavaScript (a Back button) makes react-native-screens animate a
  snapshot of the popped screen, taken in the commit that removes it. Begin the
  interaction on the UI thread first, then pop, so the target is hidden in the
  snapshot too.

### Memory: share the decode

A flight host's content is laid out at the destination size and cropped into
the card by the clip. Do not give it its own full-resolution image: in a grid,
each host would hold a full-screen decode (7.4 MB for a 1206 × 1608 photo).
Decode once at the card's pixel size and reuse that decode for the flight
content, for example with expo-image's `useImage` and its `ImageRef`:

```tsx
const thumb = useImage(photo.uri, { maxWidth: cellPx, maxHeight: cellPx });
<SmoothClipView controller={clip} flight={`gallery-${photo.id}`}>
  <Image source={thumb} style={destinationSize} contentFit="cover" />
</SmoothClipView>;
```

A flight host then costs no extra bitmap, and a few KB of native views. The
destination loads its own full-resolution image; `ready={displayed}` keeps the
flying thumbnail on screen until it has, so the two overlap only until the
reveal.

### Left out on purpose

- **Navigation.** No push, pop or router integration: call your router.
- **Gestures.** No dependency on Gesture Handler: any worklet or JS handler
  starts a flight.
- **Image loading.** The shared-decode pattern is documentation; `ready` is the
  only hook.
- **Destination rects.** The app supplies them, in window space; retarget with
  `velocity: 'inherit'` when they arrive late.
- **A `useHeroTransition()` hook, or a swipe-back helper.** They would be
  sugar over these primitives, with optional dependencies.

## Geometry and rendering

- `x` and `y` are never intersected with the host.
- Negative width and height canonicalize to zero.
- Corner-overlap scaling follows CSS rules against the requested rectangle.
- `contentTranslateX`, `contentTranslateY`, and positive `contentScale` animate
  with the aperture.
- `rotation` accepts degree or radian strings (for example, `'12deg'` or
  `'0.2rad'`) and defaults to `'0deg'`. It rotates the aperture, content, and
  shadow together, clockwise around the current aperture center. Existing
  content translation and scale happen before this rotation. The host stays
  fixed and crops the rotated result.
- `opacity` defaults to `1` and fades the aperture's content and shadow as one
  group. Finite values clamp to `[0, 1]`; malformed angles and nonfinite values
  reject the complete presentation. Spring opacity is clamped for rendering
  without clamping its internal spring state.
- Circular and continuous curves and independent corner radii are supported.
- `continuous` is the platform squircle: `CALayer.cornerCurve` on iOS for
  uniform radii, and a Figma smoothed corner at smoothing 0.6 on Android (the
  shape `react-native-fast-squircle` draws at `cornerSmoothing={0.6}`). The apex
  matches a circular corner of the same radius; the shoulders start 1.6 × the
  radius from the corner. The two platforms are close, not pixel-identical.
- Native `animateTo` runs need uniform corner radii and one curve for the whole
  run, so a uniform `continuous` clip animates natively. Unequal radii or a
  curve change are static-only: set them with `setFrame`; `animateTo` returns
  `null`.
- One outset `boxShadow` is supported. It escapes the aperture but not the host.
- `shadowRendering="baked"` on the host draws that shadow from one pre-blurred
  tile per corner-radius step (4 pt), stretched by the compositor, instead of
  blurring a path on every frame the aperture moves: a native run or a drag of
  a full-screen window then costs no per-frame blur on either platform. A tile
  is baked once per (radius step, blur, colour), about a millisecond for a
  16 pt blur, and cached for the process. Only two bakes happen on the calling
  thread: a shadow's first tile (at mount, when nothing else can be shown)
  and a run's resting target (at install, so the run ends exact). Every other
  step bakes off the frame while the nearest cached step stands in, so a drag
  that crosses radius steps never blocks a frame. It needs uniform corner radii
  and a shape at least 2 × (1.5 × blur + radius) on each side, room for two
  corner slices (unequal radii or a smaller shape keep the blur path for that
  frame or run); the tile corner
  rounds up to the next step, so a shadow corner may be up to 4 pt rounder
  than its clip, which no blur the tile was made for resolves; a run that
  changes radius, blur or colour swaps tiles in steps along the way. The baked
  shadow is drawn under the aperture on both platforms (the Android blur path
  cuts it out), so content over it should be opaque.
- `backdrop: { translateX, translateY }` on a presentation translates every
  `SmoothClipBackdropView` bound to the same controller (`controller={clip}`,
  anywhere in the tree, any number of them). The channel is part of the
  presentation, so a `setFrame` writes it in the same native call as the clip
  and a run animates it on the clip's own epoch: content that must stay
  locked to the aperture (a screen-sized canvas centred in the window) is
  sampled by the same clock as the clip, with no Reanimated mapper in
  between. The translation goes on an inner content layer; the view's own
  `transform` style stays React Native's. A backdrop that binds while a run
  is in flight adopts the driver's current value and follows from the next
  run. While no backdrop is bound the channel is not interpolated: a snapshot
  or freeze taken mid-run reports the run's target translation, which is what
  a backdrop binding at that moment adopts.
- A fully off-host aperture is not touchable, even when only its shadow overlaps.
- Descendant accessibility is hidden during autonomous native motion and restored
  from aperture/host intersection at the endpoint.

Use `getSmoothClipCapabilities()` when a consumer needs to decide whether a
complex native path can be promoted on the current platform.

### Rotate and fade a clip

Rotation and opacity are presentation fields, so they use the same controller
and group methods as geometry. For example, start a tilted, translucent card
and animate it upright:

```ts
const clip = useSmoothClipController({
  clip: { x: 24, y: 80, width: 240, height: 320, radius: 24 },
  contentTranslateX: 0,
  contentTranslateY: 0,
  rotation: '-12deg',
  opacity: 0.4,
});

// Attach this controller to <SmoothClipView controller={clip}> as above.
const reveal = () =>
  clip.react.animateTo(
    {
      clip: { x: 24, y: 80, width: 240, height: 320, radius: 24 },
      contentTranslateX: 0,
      contentTranslateY: 0,
      rotation: '0deg',
      opacity: 1,
    },
    { type: 'spring', stiffness: 180, damping: 22 }
  );
```

For gesture-driven updates, supply the same fields from a UI-runtime worklet:

```ts
clip.ui.setFrame({ ...frame, rotation: '12deg', opacity: 0.5 });
```

Angles interpolate numerically, so `'720deg'` requests two full turns from zero;
there is no automatic shortest-path wrapping. Interruption snapshots preserve
full turns and return rotation as a radian string. Each presentation is complete:
omitting rotation or opacity resets that field to its default. At zero opacity,
the content admits no new touches and is hidden from accessibility.

When upgrading to **0.4.3**, rebuild the native app (and run `pod install` on
iOS). The native presentation protocol includes new rotation and opacity
channels, so a JavaScript-only OTA update cannot upgrade an older native build.
See the [changelog](./CHANGELOG.md) for release details.

## Performance contract

- One worklet-to-native call per `ui.setFrame`, or per group batch.
- Native timing and springs run without JS work between start and completion.
- No run begins later than its install. On iOS a run begins at its install,
  as a Core Animation run committed then does: its first frame already moves.
  On Android it is anchored to the UI frame's Reanimated stamp
  (`__frameTimestamp`, the frame being produced), so it shares one epoch with
  a `withTiming` begun in that frame. On iOS the two can be up to a frame
  apart, so continue from a run with the frame `beginInteraction()` returns,
  never from a Reanimated model of it. A run that replaces a moving run starts
  from the frame on screen, at the call (see `velocity: 'inherit'` above).
- A flight costs about a millisecond of main-thread work to lift and to land,
  and nothing per frame in between on iOS.
- A host with no run in flight and no `setFrame` stream costs nothing per
  frame: iOS keeps no display link, and Android posts its frame callback only
  while a run animates. Static content (a list of cards, say) can be
  decorated with a host at no per-frame cost, and hand off to an animated
  host through the same path builder and shadow renderer.
- Content driven by Reanimated inside the host (an `Animated.View` with a
  `useAnimatedStyle`) can land a frame after the clip on iOS: Reanimated
  applies mapper props in its own display-link pass, separate from the
  worklet frame that computed them, while a native run is sampled by Core
  Animation for the same vsync. A main-thread overrun widens that to a frame
  either way. Anything that must stay locked to the aperture belongs on the
  run itself: put it in a `SmoothClipBackdropView` and drive it through the
  presentation's `backdrop` channel.
- The shadow-disabled rendering path keeps no shadow drawing resources.
- The fixed host is the maximum rendering viewport; consumers should size it to
  the region in which content and shadow may appear.
- Rotation and opacity update native compositor properties without Yoga work
  or rebuilding unchanged clipping paths. Correctly fading overlapping children
  may require offscreen compositing; large translucent groups can cost more GPU
  time than opaque ones. No rasterization or software layer is forced.

## License

MIT
