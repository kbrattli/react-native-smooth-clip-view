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

## Requirements

- React Native 0.86 or newer with the New Architecture
- React 19.2 or newer
- React Native Reanimated 4.5 or newer
- React Native Worklets 0.10.1 or newer

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

`beginInteraction()` atomically interrupts native motion and returns its visible
raw presentation. Apply the final gesture sample with `setFrame()` before calling
it when the release must start from that exact frame.

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

An animation requested before the host has a positive layout waits, then starts
with its full duration. Host loss after motion starts freezes every member and
resolves the transaction `false`. Replacement, cancellation, destruction, and
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

## Geometry and rendering

- `x` and `y` are never intersected with the host.
- Negative width and height canonicalize to zero.
- Corner-overlap scaling follows CSS rules against the requested rectangle.
- `contentTranslateX`, `contentTranslateY`, and positive `contentScale` animate
  with the aperture.
- Circular and continuous curves and independent corner radii are supported.
- One outset `boxShadow` is supported. It escapes the aperture but not the host.
- A fully off-host aperture is not touchable, even when only its shadow overlaps.
- Descendant accessibility is hidden during autonomous native motion and restored
  from aperture/host intersection at the endpoint.

Use `getSmoothClipCapabilities()` when a consumer needs to decide whether a
complex native path can be promoted on the current platform.

## Performance contract

- One worklet-to-native call per `ui.setFrame`, or per group batch.
- Native timing and springs run without JS work between start and completion.
- The shadow-disabled rendering path keeps no shadow drawing resources.
- The fixed host is the maximum rendering viewport; consumers should size it to
  the region in which content and shadow may appear.

## License

MIT
