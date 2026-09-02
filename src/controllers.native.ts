import { useEffect, useRef } from 'react';
import { scheduleOnUI } from 'react-native-worklets';
import type {
  SmoothClipController,
  SmoothClipControllerOptions,
  SmoothClipInitialFrame,
} from './controllerTypes';
import { createSmoothClipRef, setControllerRef } from './controllerInternals';
import { destroyController } from './controllerLifecycle';
import { allocateSmoothClipId } from './ids';
import {
  canonicalizeClipPresentation,
  createClipPresentation,
  type CanonicalSmoothClipPresentation,
} from './geometry';
import { useSmoothClipGroup } from './groups.native';
import { presentationPacket } from './presentationCodec';
import NativeSmoothClipModule from './smoothClipNative';

const setClipPresentationHostFunction =
  NativeSmoothClipModule.setClipPresentation;

export function useSmoothClipController(
  initialValue: SmoothClipInitialFrame,
  options: SmoothClipControllerOptions = {}
): SmoothClipController {
  // A controller is intentionally a one-member transaction group. This keeps
  // validation, native dispatch, cancellation, completion, and lifecycle races
  // on the same path as multi-member transitions.
  const group = useSmoothClipGroup(options);
  const initialRequested =
    'clip' in initialValue
      ? initialValue
      : createClipPresentation(initialValue);
  const canonicalInitial = canonicalizeClipPresentation(initialRequested);
  if (canonicalInitial === null) {
    throw new Error('[SmoothClipView] Initial presentation must be finite.');
  }
  const initialFrameRef = useRef<CanonicalSmoothClipPresentation | null>(null);
  initialFrameRef.current ??= canonicalInitial;
  const initialFrame = initialFrameRef.current;

  const idRef = useRef(0);
  const controllerRef = useRef<SmoothClipController | null>(null);
  if (idRef.current === 0) idRef.current = allocateSmoothClipId();
  const controllerId = idRef.current;

  if (controllerRef.current === null) {
    const ref = createSmoothClipRef(controllerId);
    const controller: SmoothClipController = {
      ref,
      ui: {
        beginInteraction() {
          'worklet';
          return group.ui.beginInteraction([ref])[0]?.frame ?? initialFrame;
        },
        setFrame(frame) {
          'worklet';
          group.ui.setFrames([{ clip: ref, frame }]);
        },
        animateTo(target, animation, completionTag = 0) {
          'worklet';
          return group.ui.animateTo(
            [{ clip: ref, target }],
            animation,
            completionTag
          );
        },
        cancel(run) {
          'worklet';
          return group.ui.cancel(run)[0]?.frame ?? initialFrame;
        },
      },
      react: {
        animateTo(target, animation) {
          return group.react.animateTo([{ clip: ref, target }], animation);
        },
      },
    };
    setControllerRef(controller, { ref, initialFrame });
    controllerRef.current = controller;
  }

  useEffect(() => {
    scheduleOnUI(
      (id: number, frame: CanonicalSmoothClipPresentation) => {
        'worklet';
        setClipPresentationHostFunction(
          id,
          presentationPacket(frame),
          true,
          false
        );
      },
      controllerId,
      initialFrame
    );
    return () => {
      destroyController(controllerId);
    };
  }, [controllerId, initialFrame]);

  return controllerRef.current;
}
