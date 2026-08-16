// The shared NATIVE driver: iOS and Android both execute this file, via the
// one-line re-exports in drivers.ios.ts / drivers.android.ts that Metro's
// platform resolution picks up from index.ts's `./drivers` import. Only the
// `./smoothClipNative` import below is platform-split. drivers.ts (no
// suffix) is the web/Reanimated fallback, not this driver's sibling.
import { useEffect, useRef } from 'react';
import { Platform } from 'react-native';
import { useSharedValue, type SharedValue } from 'react-native-reanimated';
import { isRNRuntime, scheduleOnRN, scheduleOnUI } from 'react-native-worklets';
import NativeSmoothClipModule from './smoothClipNative';
import type {
  ClipReduceMotion,
  KeyframedClipAnimation,
  SmoothClipAnimation,
  SmoothClipDriver,
  SmoothClipDriverOptions,
  SpringClipAnimation,
  TimingClipAnimation,
} from './driverTypes';
import {
  allocateDriverId,
  attachDriverState,
  createDriverState,
  detachDriverState,
  getDriverState,
  setDriverState,
} from './driverState';
import {
  completeNativeAnimation,
  synchronizeNativeCompletion,
} from './nativeCompletion';
import {
  clipPresentationEquals,
  createClipPresentation,
  isFiniteClipPresentation,
  type ClipGeometry,
  type SmoothClipPresentation,
} from './geometry';
import {
  createReactRequest,
  rejectDriverRequests,
  resolveReactRequest,
} from './reactRequests';

const INTERACTIVE = 0;
const NATIVE = 1;

// Only Android consumes the Reanimated start stamp (its frame-clock anchor —
// docs/android-frame-clock-anchor.md). iOS's TurboModule reads its declared
// parameters positionally and drops the trailing argument, so capturing the
// stamp there is a wasted native _getAnimationTimestamp() call per animateTo.
// Resolved once at module scope; the worklet captures the primitive.
const NEEDS_START_STAMP = Platform.OS === 'android';

const setPresentationHostFunction = NativeSmoothClipModule.setClipPresentation;
const beginInteractionHostFunction = NativeSmoothClipModule.beginInteraction;

// The animate* host functions take one argument beyond the TurboModule spec:
// the Reanimated-rule start stamp in milliseconds (see animateOnUI). Android's
// JSI bindings read it as an optional trailing argument; the iOS TurboModule
// reads its declared parameters positionally and ignores extras, so the
// codegen spec stays untouched and both platforms take the same call. A
// narrower function is assignable to the widened type, so no cast is needed.
type WithStartStamp<F> = F extends (...args: infer A) => infer R
  ? (...args: [...A, startedAtMs: number]) => R
  : never;
const animateTimingHostFunction: WithStartStamp<
  typeof NativeSmoothClipModule.animateTiming
> = NativeSmoothClipModule.animateTiming;
const animateSpringHostFunction: WithStartStamp<
  typeof NativeSmoothClipModule.animateSpring
> = NativeSmoothClipModule.animateSpring;
const animateKeyframesHostFunction: WithStartStamp<
  typeof NativeSmoothClipModule.animateKeyframes
> = NativeSmoothClipModule.animateKeyframes;
const rejectAnimationHostFunction = NativeSmoothClipModule.rejectAnimation;
const cancelAnimationHostFunction = NativeSmoothClipModule.cancelAnimation;
const destroyDriverHostFunction = NativeSmoothClipModule.destroyDriver;

// Workaround for react-native-worklets 0.10: the RN-side serialization cache
// hands out one remote-function registry id per function forever, but the
// registry entry is deleted as soon as any transient UI-side proxy of that
// function is garbage collected. A later scheduleOnRN for the same function
// then reads `undefined` from the registry and aborts in Value::getObject.
// Pinning one UI-side reference for the app lifetime keeps the proxy — and
// with it the registry entry — alive. Remove once worklets decouples registry
// cleanup from proxy lifetime.
scheduleOnUI((resolver: typeof resolveReactRequest) => {
  'worklet';
  (globalThis as Record<string, unknown>).__smoothClipPinnedResolver = resolver;
}, resolveReactRequest);

function reduceMotionCode(value: ClipReduceMotion): number {
  switch (value) {
    case 'always':
      return 1;
    case 'never':
      return 2;
    default:
      return 0;
  }
}

function animationIsFinite(animation: SmoothClipAnimation): boolean {
  'worklet';
  if (
    animation.from !== undefined &&
    !isFiniteClipPresentation(animation.from)
  ) {
    // Silently dropping an invalid explicit start would re-open the exact
    // stale-start handoff `from` exists to close — reject the whole call.
    return false;
  }
  if (animation.type === 'timing') {
    const [x1, , x2] = animation.controlPoints;
    return (
      Number.isFinite(animation.duration) &&
      animation.controlPoints.every(Number.isFinite) &&
      // A cubic-bezier easing is only defined for x within [0,1] (the CSS /
      // CoreAnimation / Reanimated Easing.bezier contract). Out-of-range x
      // makes the Android parameter solve meaningless while CoreAnimation
      // silently clamps — reject like any other invalid input instead of
      // diverging per platform.
      x1 >= 0 &&
      x1 <= 1 &&
      x2 >= 0 &&
      x2 <= 1
    );
  }
  if (animation.type === 'spring') {
    return [
      animation.mass ?? 1,
      animation.stiffness ?? 100,
      animation.damping ?? 10,
      animation.initialVelocity === 'inherit'
        ? 0
        : (animation.initialVelocity ?? 0),
    ].every(Number.isFinite);
  }
  // Keyframe frames validate inside flattenFiniteKeyframes — one traversal
  // both checks and flattens, instead of walking every frame twice. The type
  // check is statically always-true for the TS union but load-bearing for JS
  // callers: an unrecognized type must reject here, or it would skip the
  // keyframe gate entirely and hand native a null frames array.
  return animation.type === 'keyframes';
}

function presentationFromNative(
  values: ReadonlyArray<number>,
  fallback: SmoothClipPresentation,
  offset = 0
): SmoothClipPresentation {
  'worklet';
  if (values.length < offset + 7) return fallback;
  const presentation = {
    clip: {
      x: values[offset] as number,
      y: values[offset + 1] as number,
      width: values[offset + 2] as number,
      height: values[offset + 3] as number,
      radius: values[offset + 4] as number,
    },
    contentTranslateX: values[offset + 5] as number,
    contentTranslateY: values[offset + 6] as number,
  };
  return isFiniteClipPresentation(presentation) ? presentation : fallback;
}

// Validates and flattens the keyframe list in one traversal (the flat number
// array is the wire format the native side reads back positionally). Returns
// null when any frame is invalid — same rejection contract the two-pass
// validate-then-flatten had.
function flattenFiniteKeyframes(
  target: SmoothClipPresentation,
  animation: KeyframedClipAnimation
): number[] | null {
  'worklet';
  if (!Number.isFinite(animation.duration) || animation.frames.length < 2) {
    return null;
  }
  const values: number[] = [];
  let previousOffset = -1;
  for (const frame of animation.frames) {
    const { offset, presentation } = frame;
    if (
      !Number.isFinite(offset) ||
      offset < 0 ||
      offset > 1 ||
      offset <= previousOffset ||
      !isFiniteClipPresentation(presentation)
    ) {
      return null;
    }
    previousOffset = offset;
    const { clip, contentTranslateX, contentTranslateY } = presentation;
    values.push(
      offset,
      clip.x,
      clip.y,
      clip.width,
      clip.height,
      clip.radius,
      contentTranslateX,
      contentTranslateY
    );
  }
  if (
    animation.frames[0]?.offset !== 0 ||
    previousOffset !== 1 ||
    !clipPresentationEquals(
      animation.frames[animation.frames.length - 1]?.presentation ?? null,
      target
    )
  ) {
    return null;
  }
  return values;
}

function uiOnly(): never {
  'worklet';
  throw new Error(
    '[SmoothClipView] driver.ui methods must run on the UI runtime. Use driver.react from React code.'
  );
}

export function useSmoothClipDriver(
  initialValue: ClipGeometry | SmoothClipPresentation,
  options: SmoothClipDriverOptions = {}
): SmoothClipDriver {
  const initialPresentation =
    'clip' in initialValue
      ? initialValue
      : createClipPresentation(initialValue);
  const presentation = useSharedValue(initialPresentation);
  const ownership = useSharedValue(INTERACTIVE);
  const suppressDeliveries = useSharedValue(0);
  const activeAnimationId = useSharedValue(0);
  // Non-zero after a setScalars hot write: driver.presentation is then stale,
  // so animateTo must start from the native registry's latest value instead
  // of snapping back to the stale SharedValue.
  const scalarsStale = useSharedValue(0);
  // Non-zero between the effect cleanup's native teardown and the next effect
  // run. Native cannot tell "this driver was never seeded" from "this driver
  // was destroyed and erased" — both are a missing registry entry — so the
  // animation entry points would happily create a fresh state for a call that
  // arrives after the hook is gone, leaving a latch that no view starts and no
  // destroy cancels. Only the UI side knows the difference, so it is decided
  // here.
  const disposed = useSharedValue(0);
  const callbackRef = useRef(options.onAnimationComplete);
  const driverRef = useRef<SmoothClipDriver | null>(null);
  callbackRef.current = options.onAnimationComplete;

  if (driverRef.current === null) {
    const driverId = allocateDriverId();
    const reduceMotion = reduceMotionCode(options.reduceMotion ?? 'system');

    const seedPresentation = (next: SmoothClipPresentation) => {
      'worklet';
      if (clipPresentationEquals(presentation.value, next)) return;
      suppressDeliveries.value += 1;
      presentation.value = next;
      // The listener runs synchronously inside that assignment, so the credit
      // is either spent by now or was never spendable. deliver() returns before
      // the decrement whenever the value dedupes against `last` — which happens
      // exactly when native already holds it, e.g. freezing a latch back to the
      // value it started from. An unspent credit would then swallow the next
      // real declarative write and leave native a geometry behind for good.
      if (suppressDeliveries.value > 0) suppressDeliveries.value -= 1;
    };

    const beginOnUI = (): SmoothClipPresentation => {
      'worklet';
      if (disposed.value !== 0) return presentation.value;
      const current = presentationFromNative(
        beginInteractionHostFunction(driverId),
        presentation.value
      );
      activeAnimationId.value = 0;
      ownership.value = INTERACTIVE;
      scalarsStale.value = 0;
      seedPresentation(current);
      return current;
    };

    const setOnUI = (next: SmoothClipPresentation): void => {
      'worklet';
      if (disposed.value !== 0 || !isFiniteClipPresentation(next)) return;
      activeAnimationId.value = 0;
      ownership.value = INTERACTIVE;
      scalarsStale.value = 0;
      const { clip, contentTranslateX, contentTranslateY } = next;
      setPresentationHostFunction(
        driverId,
        clip.x,
        clip.y,
        clip.width,
        clip.height,
        clip.radius,
        contentTranslateX,
        contentTranslateY,
        true,
        false
      );
      seedPresentation(next);
    };

    const setScalarsOnUI = (
      x: number,
      y: number,
      width: number,
      height: number,
      radius: number,
      contentTranslateX: number,
      contentTranslateY: number,
      overridePendingAnimation = false
    ): void => {
      'worklet';
      if (
        disposed.value !== 0 ||
        !Number.isFinite(x) ||
        !Number.isFinite(y) ||
        !Number.isFinite(width) ||
        !Number.isFinite(height) ||
        !Number.isFinite(radius) ||
        !Number.isFinite(contentTranslateX) ||
        !Number.isFinite(contentTranslateY)
      ) {
        return;
      }
      if (activeAnimationId.value !== 0) activeAnimationId.value = 0;
      if (ownership.value !== INTERACTIVE) ownership.value = INTERACTIVE;
      if (scalarsStale.value === 0) scalarsStale.value = 1;
      setPresentationHostFunction(
        driverId,
        x,
        y,
        width,
        height,
        radius,
        contentTranslateX,
        contentTranslateY,
        true,
        overridePendingAnimation
      );
    };

    const animateOnUI = (
      target: SmoothClipPresentation,
      animation: SmoothClipAnimation
    ): number => {
      'worklet';
      // Cleanup owns the terminal state. Check it before validation so even an
      // invalid stale call cannot mint a native rejection id/completion against
      // a driver whose listener and registry entry are already gone.
      if (disposed.value !== 0) return 0;
      const keyframeValues =
        animation.type === 'keyframes'
          ? flattenFiniteKeyframes(target, animation)
          : null;
      if (
        !isFiniteClipPresentation(target) ||
        !animationIsFinite(animation) ||
        (animation.type === 'keyframes' && keyframeValues === null)
      ) {
        return rejectAnimationHostFunction(driverId);
      }
      // Past the hook's cleanup the native entry is gone for good, and an
      // interactive start here would recreate it as a latch nothing can ever
      // start or cancel. Reject before any side effect — not via
      // rejectAnimation, which would mint an id and a completion for a driver
      // whose JS state is already detached. This is the "unsupported dispatch"
      // arm of the documented 0 contract.
      const from = animation.from;
      if (from !== undefined) {
        // Fused hot write: exactly setScalars(from…) issued immediately
        // before the handoff, so native's latest value — the animation
        // start below — is the caller's explicit presentation. Also
        // re-grabs from a running animation, which the implicit
        // interactive-start path would silently skip.
        setScalarsOnUI(
          from.clip.x,
          from.clip.y,
          from.clip.width,
          from.clip.height,
          from.clip.radius,
          from.contentTranslateX,
          from.contentTranslateY,
          true
        );
      }

      // After a setScalars hot write the SharedValue no longer matches what
      // is on screen; passing it as the start would snap the animation back.
      // Without an interactive start, native resolves the start from its own
      // latest value instead.
      const scalarsWereStale = scalarsStale.value !== 0;
      const hasInteractiveStart =
        ownership.value === INTERACTIVE && !scalarsWereStale;
      const start = presentation.value;
      ownership.value = NATIVE;
      presentation.value = target;
      scalarsStale.value = 0;
      const startClip = start.clip;
      const targetClip = target.clip;
      // Reanimated stamps a parallel animation's t0 on this same runtime as
      // `__frameTimestamp || _getAnimationTimestamp()` (valueSetter.ts).
      // Capturing the identical value here and handing it to the integrator
      // keeps clip and content phase-locked in every branch — including a
      // start issued from CALLBACK_INPUT (batched gesture moves), where the
      // dispatching frame's stamp is EARLIER than the call: the native min()
      // anchor alone would adopt that frame stamp while Reanimated, outside
      // its rAF flush where __frameTimestamp is cleared, keeps the wall
      // clock — a lead lasting the whole animation. NaN when the globals are
      // absent (tests, non-worklets runtimes): native then falls back to its
      // own clock plus the min() anchor, the pre-stamp behavior. On iOS the
      // stamp is always NaN: Core Animation anchors at commit time and the
      // TurboModule discards the argument, so the capture would only cost.
      const workletGlobal = globalThis as {
        __frameTimestamp?: number;
        _getAnimationTimestamp?: () => number;
      };
      const startedAtMs = !NEEDS_START_STAMP
        ? Number.NaN
        : workletGlobal.__frameTimestamp ||
          (typeof workletGlobal._getAnimationTimestamp === 'function'
            ? workletGlobal._getAnimationTimestamp()
            : Number.NaN);
      let animationId: number;

      if (animation.type === 'timing') {
        const [x1, y1, x2, y2] = animation.controlPoints;
        animationId = animateTimingHostFunction(
          driverId,
          hasInteractiveStart,
          startClip.x,
          startClip.y,
          startClip.width,
          startClip.height,
          startClip.radius,
          start.contentTranslateX,
          start.contentTranslateY,
          targetClip.x,
          targetClip.y,
          targetClip.width,
          targetClip.height,
          targetClip.radius,
          target.contentTranslateX,
          target.contentTranslateY,
          Math.max(0, animation.duration),
          x1,
          y1,
          x2,
          y2,
          reduceMotion,
          startedAtMs
        );
      } else if (animation.type === 'spring') {
        const inheritVelocity =
          animation.initialVelocity === undefined ||
          animation.initialVelocity === 'inherit';
        animationId = animateSpringHostFunction(
          driverId,
          hasInteractiveStart,
          startClip.x,
          startClip.y,
          startClip.width,
          startClip.height,
          startClip.radius,
          start.contentTranslateX,
          start.contentTranslateY,
          targetClip.x,
          targetClip.y,
          targetClip.width,
          targetClip.height,
          targetClip.radius,
          target.contentTranslateX,
          target.contentTranslateY,
          Math.max(0.0001, animation.mass ?? 1),
          Math.max(0.0001, animation.stiffness ?? 100),
          Math.max(0, animation.damping ?? 10),
          inheritVelocity ? 0 : (animation.initialVelocity as number),
          inheritVelocity,
          reduceMotion,
          startedAtMs
        );
      } else {
        animationId = animateKeyframesHostFunction(
          driverId,
          hasInteractiveStart,
          startClip.x,
          startClip.y,
          startClip.width,
          startClip.height,
          startClip.radius,
          start.contentTranslateX,
          start.contentTranslateY,
          targetClip.x,
          targetClip.y,
          targetClip.width,
          targetClip.height,
          targetClip.radius,
          target.contentTranslateX,
          target.contentTranslateY,
          Math.max(0, animation.duration),
          // Non-null here: the validation gate above rejected null before any
          // side effect.
          keyframeValues as number[],
          reduceMotion,
          startedAtMs
        );
      }
      if (animationId === 0) {
        // The 0 sentinel: off-main, invalid-id, or otherwise unsupported
        // dispatch. A missing driver is accepted when this call carries the
        // authoritative interactive start above; a start-less missing-state
        // request remains unsupported rather than inventing zero geometry.
        // Validation failures never get here: they reject before any side
        // effect, with a fresh id and one finished:false completion once the
        // native entry exists — in the pre-seed window rejectAnimation has no
        // entry and returns the bare 0 sentinel with no completion instead.
        ownership.value = INTERACTIVE;
        presentation.value = start;
        if (scalarsWereStale) scalarsStale.value = 1;
        activeAnimationId.value = 0;
        return rejectAnimationHostFunction(driverId);
      }
      activeAnimationId.value = animationId;
      return animationId;
    };

    const cancelOnUI = (
      animationId = 0,
      behavior: 'current' | 'target' = 'current'
    ): SmoothClipPresentation => {
      'worklet';
      // Past the hook's cleanup the native entry is gone; the call would fail
      // defined (handled=false) but it is the last driver.ui path that still
      // crosses into native after the tombstone. Guard it like the rest.
      if (disposed.value !== 0) return presentation.value;
      const values = cancelAnimationHostFunction(
        driverId,
        animationId,
        behavior === 'target' ? 1 : 0
      );
      if (values.length < 8 || values[0] !== 1) return presentation.value;
      const current = presentationFromNative(values, presentation.value, 1);
      activeAnimationId.value = 0;
      ownership.value = INTERACTIVE;
      scalarsStale.value = 0;
      seedPresentation(current);
      return current;
    };

    const driver: SmoothClipDriver = {
      kind: 'hybrid',
      presentation,
      ui: {
        beginInteraction() {
          'worklet';
          if (isRNRuntime()) return uiOnly();
          return beginOnUI();
        },
        set(next) {
          'worklet';
          if (isRNRuntime()) return uiOnly();
          setOnUI(next);
        },
        setScalars(
          x,
          y,
          width,
          height,
          radius,
          contentTranslateX,
          contentTranslateY
        ) {
          'worklet';
          if (isRNRuntime()) return uiOnly();
          setScalarsOnUI(
            x,
            y,
            width,
            height,
            radius,
            contentTranslateX,
            contentTranslateY
          );
        },
        animateTo(target, animation) {
          'worklet';
          if (isRNRuntime()) return uiOnly();
          return animateOnUI(target, animation);
        },
        cancel(animationId = 0, behavior = 'current') {
          'worklet';
          if (isRNRuntime()) return uiOnly();
          return cancelOnUI(animationId, behavior);
        },
      },
      react: {
        beginInteraction() {
          const { requestId, promise } =
            createReactRequest<SmoothClipPresentation>(driverId);
          scheduleOnUI(() => {
            'worklet';
            const result = beginOnUI();
            scheduleOnRN(resolveReactRequest, driverId, requestId, result);
          });
          return promise;
        },
        set(next) {
          // Teardown resolves (undefined) rather than rejects: `set` is a
          // documented fire-and-forget call, and a promise discarded with
          // `void` must not become an unhandled rejection at unmount.
          const { requestId, promise } = createReactRequest<void>(
            driverId,
            false,
            { value: undefined }
          );
          scheduleOnUI(() => {
            'worklet';
            setOnUI(next);
            scheduleOnRN(resolveReactRequest, driverId, requestId, undefined);
          });
          return promise;
        },
        animateTo(target, animation) {
          // Teardown resolves with the documented 0 rejection sentinel (see
          // `set` above): the README's own example voids this promise.
          const { requestId, promise } = createReactRequest<number>(
            driverId,
            true,
            { value: 0 }
          );
          scheduleOnUI(() => {
            'worklet';
            const result = animateOnUI(target, animation);
            scheduleOnRN(
              resolveReactRequest,
              driverId,
              requestId,
              result,
              true
            );
          });
          return promise;
        },
        cancel(animationId = 0, behavior = 'current') {
          const { requestId, promise } =
            createReactRequest<SmoothClipPresentation>(driverId, true);
          scheduleOnUI(() => {
            'worklet';
            const result = cancelOnUI(animationId, behavior);
            scheduleOnRN(
              resolveReactRequest,
              driverId,
              requestId,
              result,
              true
            );
          });
          return promise;
        },
      },
    };

    setDriverState(
      driver,
      createDriverState(
        driverId,
        initialPresentation,
        presentation,
        callbackRef,
        activeAnimationId,
        ownership
      )
    );
    driverRef.current = driver;
  }

  const driver = driverRef.current;

  useEffect(() => {
    const currentDriver = driverRef.current;
    if (!currentDriver) return undefined;
    const state = getDriverState(currentDriver);
    const { driverId } = state;
    // Re-attach on every effect run: StrictMode/<Activity> replay the effect
    // after its cleanup detached this state and destroyed the native driver.
    // The authoritative seed below recreates the native entry in that case.
    attachDriverState(state);

    const subscription = NativeSmoothClipModule.onClipAnimationComplete(
      (result) => {
        if (result.driverId !== driverId) return;
        synchronizeNativeCompletion(
          activeAnimationId,
          ownership,
          result.animationId,
          result.finished
        );
        completeNativeAnimation(driverId, result.animationId, result.finished);
      }
    );

    scheduleOnUI(
      (
        source: SharedValue<SmoothClipPresentation>,
        listenerId: number,
        nativeDriverId: number,
        owner: SharedValue<number>,
        suppressed: SharedValue<number>,
        active: SharedValue<number>,
        stale: SharedValue<number>,
        gone: SharedValue<number>,
        setter: typeof setPresentationHostFunction
      ) => {
        'worklet';
        // First, before the listener or the seed: this effect run owns the
        // driver again, so a StrictMode/<Activity> replay must clear the
        // previous cleanup's tombstone or every later write would be rejected.
        gone.value = 0;
        let last: SmoothClipPresentation | null = null;
        const deliver = (next: SmoothClipPresentation) => {
          if (
            !isFiniteClipPresentation(next) ||
            clipPresentationEquals(last, next)
          ) {
            return;
          }
          // Record `last` only for values native has actually observed:
          // deliveries dropped during native ownership must stay eligible
          // for re-delivery once interactive ownership returns.
          if (owner.value !== INTERACTIVE) return;
          if (suppressed.value > 0) {
            suppressed.value -= 1;
            last = next;
            return;
          }
          last = next;
          if (stale.value !== 0) stale.value = 0;
          const { clip, contentTranslateX, contentTranslateY } = next;
          setter(
            nativeDriverId,
            clip.x,
            clip.y,
            clip.width,
            clip.height,
            clip.radius,
            contentTranslateX,
            contentTranslateY,
            false,
            false
          );
        };
        source.addListener(listenerId, deliver);
        // Authoritative take-ownership seed. Creates the native entry before
        // any view mounts on the ordinary path, and revives a driver destroyed
        // by an effect-replay cleanup (StrictMode/<Activity>) on later runs.
        // An animation worklet can win the scheduling race and create a latch
        // first; Native ownership then marks that intent as newer, so this
        // passive seed must not clear its active id or replay the target value.
        const current = source.value;
        if (owner.value === INTERACTIVE && isFiniteClipPresentation(current)) {
          active.value = 0;
          owner.value = INTERACTIVE;
          stale.value = 0;
          last = current;
          setter(
            nativeDriverId,
            current.clip.x,
            current.clip.y,
            current.clip.width,
            current.clip.height,
            current.clip.radius,
            current.contentTranslateX,
            current.contentTranslateY,
            true,
            false
          );
        }
      },
      presentation,
      driverId,
      driverId,
      ownership,
      suppressDeliveries,
      activeAnimationId,
      scalarsStale,
      disposed,
      setPresentationHostFunction
    );

    return () => {
      subscription.remove();
      rejectDriverRequests(driverId);
      detachDriverState(state);
      scheduleOnUI(
        (
          source: SharedValue<SmoothClipPresentation>,
          listenerId: number,
          nativeDriverId: number,
          owner: SharedValue<number>,
          active: SharedValue<number>,
          stale: SharedValue<number>,
          suppressed: SharedValue<number>,
          gone: SharedValue<number>,
          destroy: typeof destroyDriverHostFunction
        ) => {
          'worklet';
          source.removeListener(listenerId);
          destroy(nativeDriverId);
          // StrictMode replays the effect with these same SharedValues. Reset
          // the UI-side tombstone only after native teardown so the next setup
          // can seed or animate without inheriting stale Native ownership.
          active.value = 0;
          owner.value = INTERACTIVE;
          stale.value = 0;
          // Defensive: seedPresentation now reclaims its own unspent credit at
          // the point of issue, so this should already be 0. Kept because the
          // failure mode — one declarative write silently dropped for the rest
          // of the next hook's life — is invisible until someone reports a
          // stale clip rect.
          suppressed.value = 0;
          // Last: the native entry is now erased, so until the next effect run
          // clears this, any call that would recreate it is rejected instead.
          gone.value = 1;
        },
        presentation,
        driverId,
        driverId,
        ownership,
        activeAnimationId,
        scalarsStale,
        suppressDeliveries,
        disposed,
        destroyDriverHostFunction
      );
    };
  }, [
    activeAnimationId,
    disposed,
    ownership,
    presentation,
    scalarsStale,
    suppressDeliveries,
  ]);

  return driver;
}

export type {
  KeyframedClipAnimation,
  SpringClipAnimation,
  TimingClipAnimation,
};
