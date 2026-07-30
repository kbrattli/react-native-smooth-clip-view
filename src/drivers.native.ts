// The shared NATIVE driver: iOS and Android both execute this file, via the
// one-line re-exports in drivers.ios.ts / drivers.android.ts that Metro's
// platform resolution picks up from index.ts's `./drivers` import. Only the
// `./smoothClipNative` import below is platform-split. drivers.ts (no
// suffix) is the web/Reanimated fallback, not this driver's sibling.
import { useEffect, useRef } from 'react';
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

const setPresentationHostFunction = NativeSmoothClipModule.setClipPresentation;
const beginInteractionHostFunction = NativeSmoothClipModule.beginInteraction;
const animateTimingHostFunction = NativeSmoothClipModule.animateTiming;
const animateSpringHostFunction = NativeSmoothClipModule.animateSpring;
const animateKeyframesHostFunction = NativeSmoothClipModule.animateKeyframes;
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

function animationIsFinite(
  target: SmoothClipPresentation,
  animation: SmoothClipAnimation
): boolean {
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
    return (
      Number.isFinite(animation.duration) &&
      animation.controlPoints.every(Number.isFinite)
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
  if (!Number.isFinite(animation.duration) || animation.frames.length < 2) {
    return false;
  }
  let previousOffset = -1;
  for (const frame of animation.frames) {
    if (
      !Number.isFinite(frame.offset) ||
      frame.offset < 0 ||
      frame.offset > 1 ||
      frame.offset <= previousOffset ||
      !isFiniteClipPresentation(frame.presentation)
    ) {
      return false;
    }
    previousOffset = frame.offset;
  }
  return (
    animation.frames[0]?.offset === 0 &&
    previousOffset === 1 &&
    clipPresentationEquals(
      animation.frames[animation.frames.length - 1]?.presentation ?? null,
      target
    )
  );
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

function flattenedKeyframes(animation: KeyframedClipAnimation): number[] {
  'worklet';
  const values: number[] = [];
  for (const frame of animation.frames) {
    const { clip, contentTranslateX, contentTranslateY } = frame.presentation;
    values.push(
      frame.offset,
      clip.x,
      clip.y,
      clip.width,
      clip.height,
      clip.radius,
      contentTranslateX,
      contentTranslateY
    );
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
  const callbackRef = useRef(options.onAnimationComplete);
  const driverRef = useRef<SmoothClipDriver | null>(null);
  callbackRef.current = options.onAnimationComplete;

  if (driverRef.current === null) {
    const driverId = allocateDriverId();
    const reduceMotion = reduceMotionCode(options.reduceMotion ?? 'system');

    const seedPresentation = (next: SmoothClipPresentation) => {
      'worklet';
      if (!clipPresentationEquals(presentation.value, next)) {
        suppressDeliveries.value += 1;
        presentation.value = next;
      }
    };

    const beginOnUI = (): SmoothClipPresentation => {
      'worklet';
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
      if (!isFiniteClipPresentation(next)) return;
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
        true
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
      contentTranslateY: number
    ): void => {
      'worklet';
      if (
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
        true
      );
    };

    const animateOnUI = (
      target: SmoothClipPresentation,
      animation: SmoothClipAnimation
    ): number => {
      'worklet';
      if (
        !isFiniteClipPresentation(target) ||
        !animationIsFinite(target, animation)
      ) {
        return rejectAnimationHostFunction(driverId);
      }

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
          from.contentTranslateY
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
          reduceMotion
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
          reduceMotion
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
          flattenedKeyframes(animation),
          reduceMotion
        );
      }
      if (animationId === 0) {
        // Native rejected the transition after ownership was transferred.
        // Restore interactive ownership and the pre-animation value, then
        // emit a standalone finished:false completion so completion-driven
        // state machines observe exactly one result per animateTo call.
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
          const { requestId, promise } = createReactRequest<void>(driverId);
          scheduleOnUI(() => {
            'worklet';
            setOnUI(next);
            scheduleOnRN(resolveReactRequest, driverId, requestId, undefined);
          });
          return promise;
        },
        animateTo(target, animation) {
          const { requestId, promise } = createReactRequest<number>(
            driverId,
            true
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
        setter: typeof setPresentationHostFunction
      ) => {
        'worklet';
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
            false
          );
        };
        source.addListener(listenerId, deliver);
        // Authoritative take-ownership seed. Creates the native entry before
        // any view mounts on the first run, and revives a driver destroyed by
        // an effect-replay cleanup (StrictMode/<Activity>) on later runs.
        const current = source.value;
        if (isFiniteClipPresentation(current)) {
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
            true
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
          destroy: typeof destroyDriverHostFunction
        ) => {
          'worklet';
          source.removeListener(listenerId);
          destroy(nativeDriverId);
        },
        presentation,
        driverId,
        driverId,
        destroyDriverHostFunction
      );
    };
  }, [
    activeAnimationId,
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
