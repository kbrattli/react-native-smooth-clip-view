# Flight implementation spec (iOS and Android)

This is the contract both platforms implement for flights: `flight` on `SmoothClipView`,
`SmoothClipFlightTarget`, window-space presentations and `velocity: 'inherit'` (the API is
documented in the README, "Flights"). The JS side is in `src/` (`SmoothClipView.ios.tsx`, `SmoothClipFlightTarget.tsx`,
`groups.native.ts`), and the shared math is in `cpp/SmoothClipFlightGeometry.h`.

## Props (codegen)

- **`SmoothClipView`** gains two props:
  - `flightEnabled: boolean`, default `false`;
  - `flightTag: string`, default `''`, meaning no target.
- **`SmoothClipFlightTarget`** is a new component, named `SmoothClipFlightTarget`, with two
  props:
  - `flightTag: string`;
  - `ready: boolean`, default `true`.

  It mounts its Fabric children into an internal container it owns, and hides only that
  container. Fabric never writes to it, so the target's React styles stay true.

## Packets

- **Group motion entries** (`animateTimingGroup` and `animateSpringGroup`) have the layout
  `[driverId, flags, from×25, target×25]`.
  - Flags are bit 0 has-from, bit 1 target in window space, bit 2 from in window space.
  - Any value outside 0–7 rejects the call.
- **`setClipPresentationBatch`** entries have the layout `[driverId, presentation×25]`.
  - A negative `driverId` means that the presentation is in window space, for driver
    `-driverId`.
  - 0 is invalid.
- **`animateSpringGroup`** takes a velocity that may be NaN, meaning `velocity: 'inherit'`. An
  infinite velocity still rejects the call.

## Window space

Window-space input is resolved at the registry entry, before preflight and canonicalization, for
`animateTo` targets and from-frames, and for `setFrame` frames.

1. **Host.** Take the driver's registered host. If there is none, reject the whole call.
2. **Transform.** Compute its `HostWindowTransform`.
   - If the host is lifted into a flight, use the transform captured at lift.
   - Otherwise, compute it from the model hierarchy to the window: the layout positions plus
     each ancestor's own transform (iOS: `convertPoint:toView:` of three points; Android: walk
     the parents through `left`, `top`, scroll and `getMatrix()`).
   - On Android, window space is the host's React root (the nearest `RootView`:
     `ReactRootView`, `ReactSurfaceView` or a Modal's dialog root), at lift too: the walk to the
     window reads the transform there on its way up. Layout, safe-area insets, `measure()` and
     `measureInWindow` are relative to it, and without edge-to-edge it starts below the status
     bar. A host outside a React root uses the whole window.
   - A host in a route screen that is not attached yet ends its chain at the screen. On iOS,
     continue from the screen's `reactSuperview`, the stack.
3. **Classify.** Pass the transform through `hostWindowTransformFromAffine`. A rotation, skew or
   uneven scale rejects the whole call.
4. **Convert.** Use `presentationFromWindowSpace(window, transform, hostWidth, hostHeight)`.

## `velocity: 'inherit'` (springs, controllers and groups)

Resolve the velocity per driver, at preflight, against that entry's resolved start and target:

1. **Moving run.** If the driver has a started run that this call replaces, read that run at
   the handover (see "Replacing a moving run"):
   - its progress there: `timingRunProgress`, or for springs what the platform runs
     (iOS: `coreAnimationSpringRunProgress`; Android: the member's own scalar spring, stepped
     to the handover);
   - then `inheritedRunVelocityFrom(run.start, run.end, progress, start, target)`, the run's
     velocity projected onto the new run's own displacement, `start` → `target`. With no
     `from` this equals `inheritedRunVelocity`.
2. **Interaction.** If the driver is in an interaction with velocity samples:
   `inheritedVelocity(history, velocitySampleChannels(target), now)`.
3. **Otherwise** the velocity is 0. The way back inherits 0 too: it starts on the target where
   the flight landed, a frame nothing moved to.

Each driver's run gets its own `initialVelocity`, and `springScaleStaysPositive` runs with it.

## Replacing a moving run

A call that replaces a started run (a retarget, a release) hands over at one moment, the
**handover**:

- the new run starts where the replaced run is at the handover (unless `from` or the way back
  sets the start);
- inherit reads the replaced run at the handover;
- the new run's elapsed 0 is the handover, and no frame shows the new run's start before it.

The whole call shares one handover and one epoch, and no run begins later than its install.

- **iOS.** The handover is the call: a replacement's start is what the presentation layers
  show then, inherit reads the replaced run then, and every run in the call begins at its
  install, on Core Animation's clock, as the replaced run did. The caller's frame stamp is not
  used. It is the display link's `targetTimestamp`, which can lie a frame on either side of the
  install: begun at it, a run would show its start twice, or skip ahead of the frame on screen.
  A `withTiming` begun in the same frame can therefore lead or trail the run by up to a frame.
- **Android.** A worklet's stamp is the frame being produced (Reanimated's rAF time is that
  `doFrame`'s frame time, and the registry's frame loop runs in the same `doFrame`, before the
  traversal). The handover is the stamp, or the replaced run's last frame if that is later
  (C5, a stamp behind the frame on screen: the new run begins partway through, from that
  frame): `replacementHandoverS`. The replaced run is sampled there from its own description
  (timing curve, or its springs stepped from their last frame), whether or not the frame loop
  already advanced it to that frame. A stamp ahead of the wall clock starts any run at the
  call, unanchored (`resolveStartStamp`); none Reanimated gives is: the frame time is that
  frame's vsync, and outside a frame the stamp is `SystemClock.uptimeMillis()`, on the same
  monotonic clock.
- **Both.** A group that cannot start in the call (a host not displayable yet) hands over at
  the frame its hosts hold: the replaced run's last frame on Android, the call on iOS. On iOS
  it begins at the install its host's display allows, from its start.

## Flight behaviour (hosts with `flightEnabled`)

1. **Lift.** It happens when a run installs, and on `beginInteraction`, if the host is not
   already lifted.
   - Capture the host's `HostWindowTransform` and its current canonical presentation, which
     becomes the rest presentation.
   - Add a carrier to the window's flight layer. The layer is created lazily, kept above every
     screen, never hit-testable, and hidden from accessibility (iOS:
     `accessibilityElementsHidden`, `zPosition` 1000; Android: the last child of
     `android.R.id.content`, with `IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS`).
   - The carrier has the host's size and is drawn through the transform.
   - Move the host's presentation container into the carrier. Fabric children stay in the
     content container.
   - If `flightTag` is set, hide the registered, attached target with that tag.
     - iOS: before a mount transaction deletes a hidden target that is still in a window,
       the target has the hide drawn (`snapshotViewAfterScreenUpdates:YES`, discarded). The
       way back usually pops the target's screen within a frame of the lift, and
       react-native-screens snapshots a popped screen from the last drawn frame. Without
       this, that snapshot shows the target, which then fades out with the pop under the
       flight, as a ghost.
   - **Direction.** If that target was attached and visible at lift, the flight _departs_ from it
     (the way back, or a route-hosted flight leaving its card). Otherwise the flight _lands on_
     it. Only a landing flight can hand off to its target.
2. **While lifted:**
   - The host counts as displayable even if its own screen detaches. That detach is not host
     loss.
   - A target with the same tag that registers or attaches hides immediately.
3. **Landing.** When the run ends, finished or cancelled, take the first case that applies:
   - **Cancelled.** If the run did not finish, never hand off. Return the container and reveal
     any target that was hidden.
   - **Handoff.** The flight is a landing flight, and a target with the tag is registered,
     attached, out of any screen transition, and `ready`. In one transaction:
     1. reveal the target;
     2. move the container back into the host;
     3. reset the host to the rest presentation through the registry, so that the registry's
        latest presentation is the rest presentation;
     4. remember the landed presentation (the run's end) for the way back;
     5. remove the carrier.
   - **Wait.** A landing flight's target exists but is not ready, or is mid-transition. Keep the
     flight content in the layer at its final frame, and retry when either changes.
     - A target that is registered (mounted) but not yet attached counts as arriving for up to
       300 ms: react-native-screens attaches a pushed screen one message after its mount.
     - A departing flight whose target is still attached and mid-transition (a pop) returns its
       container, but keeps the target covered until that transition ends.
   - **Return.** The host is attached and its screen is not mid-transition. Move the container
     back; the host keeps its landed presentation, with no reset. Reveal any target that was
     hidden.
   - **Fallback.** The host is detached and there is no target. Wait for the host to attach,
     or for 300 ms, then return the container into the host. Reveal any target that was
     hidden.
   - **Lost target.** A landing flight saw a target with its tag mount at some point of the
     lift, and has none attached when Return or Fallback applies: the target unmounted (its
     route was popped mid-flight and nothing flew the host home), or it stayed detached past
     the 300 ms. The flight arrived somewhere that is gone. The container goes back as in
     Return or Fallback, but the host lands as in a handoff with nothing to reveal: the
     registry resets it to the rest presentation and remembers the landed presentation.
     Left at its landed presentation, the host would show the destination frame on its own
     screen for good. A flight whose target never mounted is not a lost target.
4. **The way back.** A new run on a host with a landed record, while the paired target is
   attached and visible, starts from the landed presentation, as if `from` had been given. The
   lift then hides the target.
5. **Host loss** while lifted (the host is deleted or dropped, or its controller is destroyed).
   - iOS: the flight lands visually on its own. Before Fabric removes the host's children, take
     a render-server snapshot of the content.
   - Android: land at once, by removing the carrier and revealing the target. A destroyed
     controller lands its airborne host as a cancelled run, whatever holds the lift (a run,
     an interaction, a landing waiting for its target).
6. **Interaction.** `setFrame` writes to the lifted container. The next run continues in the
   same lift. A lifted host does not land while an interaction holds it, with one exception:
   an interaction that departed from a target that then leaves the registry (it unmounted with
   the route that drove the interaction, which followed its own dismissal) has nothing left to
   end it. The hold ends, and the flight lands as a lost target: the host goes back to rest,
   once it is out of its screen transition.
   - `beginInteraction` on a host with a landed record, while the paired target is attached and
     visible, starts from the landed presentation, as a run does on the way back. Otherwise the
     lift would hide the target while the content jumped back to the rest frame.
7. **Platform notes.** On Android the carrier covers the whole layer and carries the
   presentation's opacity while airborne. With an alpha below 1, HWUI would draw the host through
   an offscreen buffer clipped to its bounds.
   - Android: Fabric can drop a target that is still in a window, because react-native-screens
     keeps a popped screen's views attached and drawn through its exit animation. Such a target
     stays registered until it leaves the window: a lift hides it (and departs from it if it is
     visible), no landing hands off to it or reveals it, and it is revealed and unregistered
     when it leaves the window.
   - Android: a held landing is retried when its target registers, attaches, detaches, is
     dropped or changes `ready`. Only what no callback reports (a screen transition, the
     300 ms deadlines, a pending uncover) is polled, once per frame.

## Tests each platform needs

- Window-space conversion:
  - identity;
  - translation;
  - uniform scale 0.9;
  - a transform with rotation, which is rejected;
  - Android: a React root that does not start at the window origin.
- Inherited velocity:
  - a timing run replaced at half its duration;
  - a spring run replaced;
  - a host at rest, which inherits 0.
- Lift and land:
  - the target is hidden at lift and revealed at landing;
  - the host is at rest after the handoff;
  - the way back starts from the landed presentation;
  - a target that is not ready holds the landing until `ready` turns true;
  - a target that mounts while the flight is airborne mounts hidden;
  - a landing flight that lost its target leaves the host at rest, and one whose target never
    mounted returns where it landed;
  - host loss mid-flight;
  - an interaction that departed from a target that unmounts lands with the host at rest;
  - Android: a landing held only for `ready` posts no frame retries;
  - Android: a target dropped while its exiting screen still draws it stays hidden, also from a
    lift after the drop, and is never landed on.
