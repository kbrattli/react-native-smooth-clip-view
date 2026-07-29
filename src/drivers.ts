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
import {
  createClipPresentation,
  clipPresentationEquals,
  isFiniteClipPresentation,
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
  let previousOffset = -1;
  if (!Number.isFinite(animation.duration) || animation.frames.length < 2) {
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

function interpolatePresentation(
  from: SmoothClipPresentation,
  to: SmoothClipPresentation,
  progress: number
): SmoothClipPresentation {
  'worklet';
  const mix = (start: number, end: number) => start + (end - start) * progress;
  return {
    clip: {
      x: mix(from.clip.x, to.clip.x),
      y: mix(from.clip.y, to.clip.y),
      width: mix(from.clip.width, to.clip.width),
      height: mix(from.clip.height, to.clip.height),
      radius: mix(from.clip.radius, to.clip.radius),
    },
    contentTranslateX: mix(from.contentTranslateX, to.contentTranslateX),
    contentTranslateY: mix(from.contentTranslateY, to.contentTranslateY),
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
  const initialPresentation =
    'clip' in initialValue
      ? initialValue
      : createClipPresentation(initialValue);
  const presentation = useSharedValue(initialPresentation);
  const activeAnimationId = useSharedValue(0);
  const nextAnimationId = useSharedValue(0);
  const latestTarget = useSharedValue(initialPresentation);
  const animationStart = useSharedValue(initialPresentation);
  const animationProgress = useSharedValue(0);
  const keyframes = useSharedValue<
    readonly Readonly<{
      offset: number;
      presentation: SmoothClipPresentation;
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

    const beginOnUI = (): SmoothClipPresentation => {
      'worklet';
      cancelReanimatedAnimation(animationProgress);
      activeAnimationId.value = 0;
      return presentation.value;
    };

    const setOnUI = (next: SmoothClipPresentation): void => {
      'worklet';
      if (!isFiniteClipPresentation(next)) return;
      cancelReanimatedAnimation(animationProgress);
      activeAnimationId.value = 0;
      latestTarget.value = next;
      presentation.value = next;
    };

    const animateOnUI = (
      next: SmoothClipPresentation,
      animation: SmoothClipAnimation
    ): number => {
      'worklet';
      nextAnimationId.value = (nextAnimationId.value % 0x7ffffffe) + 1;
      const animationId = nextAnimationId.value;
      if (!isFiniteClipPresentation(next) || !animationIsFinite(animation)) {
        scheduleOnRN(finishFallback, driverId, animationId, false);
        return animationId;
      }

      if (animation.from !== undefined) {
        // Fused explicit start: on the fallback driver the setScalars hot
        // path is a plain presentation write, so the desugar is the same.
        presentation.value = animation.from;
      }
      activeAnimationId.value = animationId;
      animationStart.value = presentation.value;
      latestTarget.value = next;
      keyframes.value = [];
      animationProgress.value = 0;
      scheduleOnRN(snapshotDriverViews, driverId, animationId);
      const onComplete = (finished?: boolean) => {
        'worklet';
        if (activeAnimationId.value === animationId) {
          activeAnimationId.value = 0;
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
        if (
          !clipPresentationEquals(
            animation.frames[animation.frames.length - 1]?.presentation ?? null,
            next
          )
        ) {
          scheduleOnRN(finishFallback, driverId, animationId, false);
          activeAnimationId.value = 0;
          return animationId;
        }
        keyframes.value = animation.frames;
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
    ): SmoothClipPresentation => {
      'worklet';
      if (animationId !== 0 && animationId !== activeAnimationId.value) {
        return presentation.value;
      }
      cancelReanimatedAnimation(animationProgress);
      activeAnimationId.value = 0;
      if (behavior === 'target') presentation.value = latestTarget.value;
      return presentation.value;
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
        animateTo: animateOnUI,
        cancel: cancelOnUI,
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
        activeAnimationId
      )
    );
    driverRef.current = driver;
  }

  const driver = driverRef.current;
  useEffect(() => {
    const currentDriver = driverRef.current;
    if (!currentDriver) return undefined;
    const state = getDriverState(currentDriver);
    // Re-attach on effect replays (StrictMode/<Activity>) after a cleanup
    // detached this state.
    attachDriverState(state);
    return () => {
      cancelReanimatedAnimation(animationProgress);
      rejectDriverRequests(state.driverId);
      detachDriverState(state);
    };
  }, [animationProgress]);
  return driver;
}

export type {
  KeyframedClipAnimation,
  SpringClipAnimation,
  TimingClipAnimation,
};
