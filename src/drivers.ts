import { useEffect, useRef } from 'react';
import {
  cancelAnimation as cancelReanimatedAnimation,
  Easing,
  ReduceMotion,
  useAnimatedReaction,
  useSharedValue,
  withSpring,
  withTiming,
} from 'react-native-reanimated';
import { scheduleOnRN, scheduleOnUI } from 'react-native-worklets';
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
  deliverDriverCompletion,
  detachDriverState,
  finishDriverAnimation,
  getDriverState,
  setDriverState,
  snapshotDriverViews,
} from './driverState';
import { allocateFallbackAnimationId } from './fallbackAnimationId';
import {
  canonicalizeClipPresentation,
  createClipPresentation,
  clipPresentationEquals,
  isFiniteClipPresentation,
  type CanonicalSmoothClipPresentation,
  type ClipGeometry,
  type SmoothClipPresentation,
} from './geometry';
import {
  createReactRequest,
  rejectDriverRequests,
  resolveReactRequest,
} from './reactRequests';

function toReanimatedReduceMotion(value: ClipReduceMotion): ReduceMotion {
  switch (value) {
    case 'always':
      return ReduceMotion.Always;
    case 'never':
      return ReduceMotion.Never;
    default:
      return ReduceMotion.System;
  }
}

function animationIsFinite(animation: SmoothClipAnimation): boolean {
  'worklet';
  if (
    animation.from !== undefined &&
    !isFiniteClipPresentation(animation.from)
  ) {
    return false;
  }
  if (animation.type === 'timing') {
    const [x1, , x2] = animation.controlPoints;
    return (
      Number.isFinite(animation.duration) &&
      animation.duration >= 0 &&
      animation.controlPoints.every(Number.isFinite) &&
      x1 >= 0 &&
      x1 <= 1 &&
      x2 >= 0 &&
      x2 <= 1
    );
  }
  if (animation.type === 'spring') {
    const mass = animation.mass ?? 1;
    const stiffness = animation.stiffness ?? 100;
    const damping = animation.damping ?? 10;
    const initialVelocity =
      animation.initialVelocity === 'inherit'
        ? 0
        : (animation.initialVelocity ?? 0);
    return (
      [mass, stiffness, damping, initialVelocity].every(Number.isFinite) &&
      mass > 0 &&
      stiffness > 0 &&
      damping >= 0
    );
  }
  if (animation.type !== 'keyframes') return false;
  let previousOffset = -1;
  if (
    !Number.isFinite(animation.duration) ||
    animation.duration < 0 ||
    animation.frames.length < 2
  ) {
    return false;
  }
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
  return animation.frames[0]?.offset === 0 && previousOffset === 1;
}

function springScaleIsProvablyPositive(
  start: CanonicalSmoothClipPresentation,
  target: CanonicalSmoothClipPresentation,
  animation: SpringClipAnimation
): boolean {
  'worklet';
  if (start.contentScale === target.contentScale) return true;
  const mass = animation.mass ?? 1;
  const stiffness = animation.stiffness ?? 100;
  const damping = animation.damping ?? 10;
  return (
    animation.initialVelocity === 0 && damping * damping >= 4 * mass * stiffness
  );
}

function interpolatePresentation(
  from: CanonicalSmoothClipPresentation,
  to: CanonicalSmoothClipPresentation,
  progress: number
): CanonicalSmoothClipPresentation {
  'worklet';
  const mix = (start: number, end: number) => start + (end - start) * progress;
  const topLeftRadius = mix(from.clip.topLeftRadius, to.clip.topLeftRadius);
  const topRightRadius = mix(from.clip.topRightRadius, to.clip.topRightRadius);
  const bottomRightRadius = mix(
    from.clip.bottomRightRadius,
    to.clip.bottomRightRadius
  );
  const bottomLeftRadius = mix(
    from.clip.bottomLeftRadius,
    to.clip.bottomLeftRadius
  );
  const uniform =
    topLeftRadius === topRightRadius &&
    topLeftRadius === bottomRightRadius &&
    topLeftRadius === bottomLeftRadius;
  return {
    clip: {
      x: mix(from.clip.x, to.clip.x),
      y: mix(from.clip.y, to.clip.y),
      width: mix(from.clip.width, to.clip.width),
      height: mix(from.clip.height, to.clip.height),
      radius: uniform ? topLeftRadius : 0,
      topLeftRadius,
      topRightRadius,
      bottomRightRadius,
      bottomLeftRadius,
      curve: from.clip.curve,
    },
    contentTranslateX: mix(from.contentTranslateX, to.contentTranslateX),
    contentTranslateY: mix(from.contentTranslateY, to.contentTranslateY),
    contentScale: mix(from.contentScale, to.contentScale),
  };
}

function finishFallback(
  driverId: number,
  animationId: number,
  finished: boolean
): void {
  deliverDriverCompletion(
    driverId,
    animationId,
    finishDriverAnimation(driverId, animationId, finished)
  );
}

export function useSmoothClipDriver(
  initialValue: ClipGeometry | SmoothClipPresentation,
  options: SmoothClipDriverOptions = {}
): SmoothClipDriver {
  const requestedInitialPresentation =
    'clip' in initialValue
      ? initialValue
      : createClipPresentation(initialValue);
  const initialPresentation = canonicalizeClipPresentation(
    requestedInitialPresentation
  );
  if (initialPresentation === null) {
    throw new Error('[SmoothClipView] Initial presentation must be finite.');
  }
  const presentation =
    useSharedValue<SmoothClipPresentation>(initialPresentation);
  const ownership = useSharedValue(0);
  const disposed = useSharedValue(0);
  const ready = useSharedValue(0);
  const activeAnimationId = useSharedValue(0);
  const latestTarget =
    useSharedValue<CanonicalSmoothClipPresentation>(initialPresentation);
  const animationStart =
    useSharedValue<CanonicalSmoothClipPresentation>(initialPresentation);
  const animationProgress = useSharedValue(0);
  const keyframes = useSharedValue<
    readonly Readonly<{
      offset: number;
      presentation: CanonicalSmoothClipPresentation;
    }>[]
  >([]);
  const callbackRef = useRef(options.onAnimationComplete);
  const driverRef = useRef<SmoothClipDriver | null>(null);
  callbackRef.current = options.onAnimationComplete;

  useAnimatedReaction(
    () => animationProgress.value,
    (progress) => {
      const frames = keyframes.value;
      if (frames.length >= 2) {
        let upperIndex = 1;
        while (
          upperIndex < frames.length - 1 &&
          progress > (frames[upperIndex]?.offset ?? 1)
        ) {
          upperIndex += 1;
        }
        const lower = frames[upperIndex - 1];
        const upper = frames[upperIndex];
        if (!lower || !upper) return;
        const span = upper.offset - lower.offset;
        const localProgress = span <= 0 ? 1 : (progress - lower.offset) / span;
        presentation.value = interpolatePresentation(
          lower.presentation,
          upper.presentation,
          Math.min(1, Math.max(0, localProgress))
        );
        return;
      }
      presentation.value = interpolatePresentation(
        animationStart.value,
        latestTarget.value,
        progress
      );
    },
    [animationProgress, animationStart, keyframes, latestTarget, presentation]
  );

  if (driverRef.current === null) {
    const driverId = allocateDriverId();
    const reduceMotion = toReanimatedReduceMotion(
      options.reduceMotion ?? 'system'
    );

    const beginOnUI = (): CanonicalSmoothClipPresentation => {
      'worklet';
      cancelReanimatedAnimation(animationProgress);
      activeAnimationId.value = 0;
      ownership.value = 0;
      return (
        canonicalizeClipPresentation(presentation.value) ?? initialPresentation
      );
    };

    const setOnUI = (next: SmoothClipPresentation): void => {
      'worklet';
      const canonical = canonicalizeClipPresentation(next);
      if (canonical === null) return;
      cancelReanimatedAnimation(animationProgress);
      activeAnimationId.value = 0;
      ownership.value = 0;
      latestTarget.value = canonical;
      presentation.value = canonical;
    };

    const animateOnUI = (
      next: SmoothClipPresentation,
      animation: SmoothClipAnimation
    ): number => {
      'worklet';
      const animationId = allocateFallbackAnimationId();
      const canonicalNext = canonicalizeClipPresentation(next);
      const canonicalFrom =
        animation.from === undefined
          ? undefined
          : canonicalizeClipPresentation(animation.from);
      if (
        canonicalNext === null ||
        (animation.from !== undefined && canonicalFrom === null) ||
        !animationIsFinite(animation)
      ) {
        scheduleOnRN(finishFallback, driverId, animationId, false);
        return animationId;
      }
      const resolvedFrom = canonicalFrom ?? undefined;

      const current =
        canonicalizeClipPresentation(presentation.value) ?? initialPresentation;
      if (canonicalNext.clip.curve !== (resolvedFrom ?? current).clip.curve) {
        scheduleOnRN(finishFallback, driverId, animationId, false);
        return animationId;
      }

      let canonicalKeyframes:
        | {
            offset: number;
            presentation: CanonicalSmoothClipPresentation;
          }[]
        | null = null;
      if (animation.type === 'keyframes') {
        canonicalKeyframes = [];
        for (const frame of animation.frames) {
          const canonical = canonicalizeClipPresentation(frame.presentation);
          if (
            canonical === null ||
            canonical.clip.curve !== canonicalNext.clip.curve
          ) {
            scheduleOnRN(finishFallback, driverId, animationId, false);
            return animationId;
          }
          canonicalKeyframes.push({
            offset: frame.offset,
            presentation: canonical,
          });
        }
        if (
          !clipPresentationEquals(
            canonicalKeyframes[canonicalKeyframes.length - 1]?.presentation ??
              null,
            canonicalNext
          ) ||
          (resolvedFrom !== undefined &&
            !clipPresentationEquals(
              canonicalKeyframes[0]?.presentation ?? null,
              resolvedFrom
            ))
        ) {
          scheduleOnRN(finishFallback, driverId, animationId, false);
          return animationId;
        }
        if (resolvedFrom === undefined && canonicalKeyframes[0]) {
          canonicalKeyframes[0] = {
            ...canonicalKeyframes[0],
            presentation: current,
          };
        }
      }

      if (
        animation.type === 'spring' &&
        !springScaleIsProvablyPositive(
          resolvedFrom ?? current,
          canonicalNext,
          animation
        )
      ) {
        scheduleOnRN(finishFallback, driverId, animationId, false);
        return animationId;
      }

      if (resolvedFrom !== undefined) {
        // Fused explicit start: on the fallback driver the setScalars hot
        // path is a plain presentation write, so the desugar is the same.
        presentation.value = resolvedFrom;
      }
      activeAnimationId.value = animationId;
      ownership.value = 1;
      animationStart.value =
        canonicalizeClipPresentation(presentation.value) ?? initialPresentation;
      latestTarget.value = canonicalNext;
      keyframes.value = [];
      animationProgress.value = 0;
      scheduleOnRN(snapshotDriverViews, driverId, animationId);
      const onComplete = (finished?: boolean) => {
        'worklet';
        if (activeAnimationId.value === animationId) {
          activeAnimationId.value = 0;
          ownership.value = 0;
        }
        scheduleOnRN(finishFallback, driverId, animationId, finished === true);
      };

      if (animation.type === 'timing') {
        const [x1, y1, x2, y2] = animation.controlPoints;
        animationProgress.value = withTiming(
          1,
          {
            duration: Math.max(0, animation.duration),
            easing: Easing.bezier(x1, y1, x2, y2),
            reduceMotion,
          },
          onComplete
        );
      } else if (animation.type === 'spring') {
        const configuredVelocity = animation.initialVelocity;
        animationProgress.value = withSpring(
          1,
          {
            damping: animation.damping ?? 10,
            mass: animation.mass ?? 1,
            reduceMotion,
            stiffness: animation.stiffness ?? 100,
            // The fallback driver cannot sample native presentation motion,
            // so 'inherit' (and undefined) degrade to zero launch velocity.
            velocity:
              typeof configuredVelocity === 'number' ? configuredVelocity : 0,
          },
          onComplete
        );
      } else {
        keyframes.value = canonicalKeyframes!;
        animationProgress.value = withTiming(
          1,
          {
            duration: Math.max(0, animation.duration),
            easing: Easing.linear,
            reduceMotion,
          },
          onComplete
        );
      }
      return animationId;
    };

    const cancelOnUI = (
      animationId = 0,
      behavior: 'current' | 'target' = 'current'
    ): CanonicalSmoothClipPresentation => {
      'worklet';
      const current =
        canonicalizeClipPresentation(presentation.value) ?? initialPresentation;
      if (animationId !== 0 && animationId !== activeAnimationId.value) {
        return current;
      }
      cancelReanimatedAnimation(animationProgress);
      activeAnimationId.value = 0;
      ownership.value = 0;
      if (behavior === 'target') presentation.value = latestTarget.value;
      return (
        canonicalizeClipPresentation(presentation.value) ?? initialPresentation
      );
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
      setOnUI({
        clip: { x, y, width, height, radius },
        contentTranslateX,
        contentTranslateY,
      });
    };

    const setPresentationScalarsOnUI = (
      x: number,
      y: number,
      width: number,
      height: number,
      topLeftRadius: number,
      topRightRadius: number,
      bottomRightRadius: number,
      bottomLeftRadius: number,
      curveCode: number,
      contentTranslateX: number,
      contentTranslateY: number,
      contentScale: number
    ): void => {
      'worklet';
      if (curveCode !== 0 && curveCode !== 1) return;
      const uniform =
        topLeftRadius === topRightRadius &&
        topLeftRadius === bottomRightRadius &&
        topLeftRadius === bottomLeftRadius;
      setOnUI({
        clip: {
          x,
          y,
          width,
          height,
          radius: uniform ? topLeftRadius : 0,
          topLeftRadius,
          topRightRadius,
          bottomRightRadius,
          bottomLeftRadius,
          curve: curveCode === 1 ? 'continuous' : 'circular',
        },
        contentTranslateX,
        contentTranslateY,
        contentScale,
      });
    };

    const driver: SmoothClipDriver = {
      kind: 'hybrid',
      presentation,
      // Every worklet here shares the single JS runtime, so unlike the native
      // driver there is no runtime guard on `ui`: calling it from React code
      // is harmless in this fallback.
      ui: {
        beginInteraction: beginOnUI,
        set: setOnUI,
        setScalars: setScalarsOnUI,
        setPresentationScalars: setPresentationScalarsOnUI,
        animateTo: animateOnUI,
        cancel: cancelOnUI,
      },
      react: {
        beginInteraction() {
          const { requestId, promise } =
            createReactRequest<CanonicalSmoothClipPresentation>(driverId);
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
        animateTo(next, animation) {
          const { requestId, promise } = createReactRequest<number>(
            driverId,
            true
          );
          scheduleOnUI(() => {
            'worklet';
            const result = animateOnUI(next, animation);
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
            createReactRequest<CanonicalSmoothClipPresentation>(driverId, true);
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
      __smoothClipHandle: {
        driverId,
        presentation,
        ownership,
        activeAnimationId,
        disposed,
        ready,
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
        ownership,
        ready
      )
    );
    driverRef.current = driver;
  }

  const driver = driverRef.current;
  useEffect(() => {
    const currentDriver = driverRef.current;
    if (!currentDriver) return undefined;
    const state = getDriverState(currentDriver);
    disposed.value = 0;
    // Re-attach on effect replays (StrictMode/<Activity>) after a cleanup
    // detached this state.
    attachDriverState(state);
    return () => {
      cancelReanimatedAnimation(animationProgress);
      disposed.value = 1;
      rejectDriverRequests(state.driverId);
      detachDriverState(state);
    };
  }, [animationProgress, disposed]);
  return driver;
}

export type {
  KeyframedClipAnimation,
  SpringClipAnimation,
  TimingClipAnimation,
};
