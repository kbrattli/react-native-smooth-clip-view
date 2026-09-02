import { useEffect, useRef } from 'react';
import { Platform } from 'react-native';
import { scheduleOnRN, scheduleOnUI } from 'react-native-worklets';
import type {
  ClipReduceMotion,
  SmoothClipAnimation,
  SmoothClipCompletion,
  SmoothClipReactRun,
  SmoothClipRef,
  SmoothClipRunHandle,
} from './controllerTypes';
import {
  unwrapSmoothClipRef,
  type InternalSmoothClipRef,
} from './controllerInternals';
import { allocateSmoothClipId } from './ids';
import { canonicalizeClipPresentation } from './geometry';
import type {
  SmoothClipGroup,
  SmoothClipGroupFrame,
  SmoothClipGroupOptions,
  SmoothClipGroupSnapshot,
  SmoothClipGroupTarget,
} from './groupTypes';
import { subscribeGroupCompletion } from './nativeCompletion';
import {
  appendPresentationPacket,
  PRESENTATION_STRIDE,
  presentationFromPacket,
} from './presentationCodec';
import NativeSmoothClipModule from './smoothClipNative';

const beginGroupInteractionHostFunction =
  NativeSmoothClipModule.beginGroupInteraction;
const snapshotGroupHostFunction = NativeSmoothClipModule.snapshotGroup;
const setClipPresentationBatchHostFunction =
  NativeSmoothClipModule.setClipPresentationBatch;
const animateTimingGroupHostFunction =
  NativeSmoothClipModule.animateTimingGroup;
const animateSpringGroupHostFunction =
  NativeSmoothClipModule.animateSpringGroup;
const cancelAnimationGroupHostFunction =
  NativeSmoothClipModule.cancelAnimationGroup;

const SNAPSHOT_STRIDE = PRESENTATION_STRIDE + 1;
const MOTION_ENTRY_STRIDE = PRESENTATION_STRIDE * 2 + 2;
const NEEDS_START_STAMP = Platform.OS === 'android';
const DEFAULT_MASS = 4;
const DEFAULT_STIFFNESS = 900;
const DEFAULT_DAMPING = 120;
const DEFAULT_ENERGY_THRESHOLD = 6e-9;

type InternalRunHandle = SmoothClipRunHandle &
  Readonly<{
    controllerId: number;
    id: number;
    refs: readonly SmoothClipRef[];
  }>;

type PendingRun = {
  controllerId: number;
  settled: boolean;
  cancelRequested: boolean;
  refs: readonly SmoothClipRef[];
  resolve(finished: boolean): void;
  resolveNativeId(id: number): void;
  nativeId: Promise<number>;
};

type GroupState = {
  callbackRef: {
    current: ((result: SmoothClipCompletion) => void) | undefined;
  };
  runs: Map<number, PendingRun>;
  deferredCompletions: Map<
    number,
    Readonly<{
      completionTag: number;
      finished: boolean;
      snapshots: readonly number[];
    }>
  >;
  deliveredCompletions: Set<number>;
};

const groupStates = new Map<number, GroupState>();
const clientRuns = new Map<number, PendingRun>();
let nextClientRunId = 0;

function internalRef(ref: SmoothClipRef): InternalSmoothClipRef {
  'worklet';
  const internal = unwrapSmoothClipRef(ref);
  if (!internal) {
    throw new Error('[SmoothClipView] A group received an invalid clip ref.');
  }
  return internal;
}

function validatedRefs(
  refs: readonly SmoothClipRef[]
): readonly InternalSmoothClipRef[] {
  'worklet';
  if (refs.length === 0) {
    throw new Error('[SmoothClipView] A group must contain a clip.');
  }
  const seen: Record<string, true> = {};
  return refs.map((ref) => {
    const internal = internalRef(ref);
    const key = String(internal.id);
    if (seen[key]) {
      throw new Error(
        '[SmoothClipView] A group cannot contain duplicate clips.'
      );
    }
    seen[key] = true;
    return internal;
  });
}

function snapshotsFromPacket(
  refs: readonly SmoothClipRef[],
  values: readonly number[]
): readonly SmoothClipGroupSnapshot[] {
  'worklet';
  if (values.length !== refs.length * SNAPSHOT_STRIDE) {
    throw new Error(
      '[SmoothClipView] Native returned an invalid group snapshot.'
    );
  }
  return refs.map((clip, index) => {
    const offset = index * SNAPSHOT_STRIDE;
    const ready = values[offset];
    const frame = presentationFromPacket(values, offset + 1);
    if ((ready !== 0 && ready !== 1) || frame === null) {
      throw new Error(
        '[SmoothClipView] Native returned an invalid group snapshot.'
      );
    }
    return { clip, frame, ready: ready === 1 };
  });
}

function beginGroupOnUI(
  refs: readonly SmoothClipRef[]
): readonly SmoothClipGroupSnapshot[] {
  'worklet';
  const internals = validatedRefs(refs);
  return snapshotsFromPacket(
    refs,
    beginGroupInteractionHostFunction(internals.map((ref) => ref.id))
  );
}

function setFramesOnUI(entries: readonly SmoothClipGroupFrame[]): void {
  'worklet';
  const internals = validatedRefs(entries.map((entry) => entry.clip));
  const packet: number[] = [];
  entries.forEach((entry, index) => {
    const frame = canonicalizeClipPresentation(entry.frame);
    if (frame === null) {
      throw new Error('[SmoothClipView] A group frame is invalid.');
    }
    packet.push(internals[index]?.id ?? 0);
    appendPresentationPacket(packet, frame);
  });
  // A UI frame can race the Fabric host's first native registration (or its
  // teardown). That is an availability result, not malformed input. The next
  // streamed frame retries, while beginInteraction remains the explicit
  // readiness gate for an atomic handoff.
  setClipPresentationBatchHostFunction(packet);
}

function reduceMotionCode(value: ClipReduceMotion | undefined): number {
  'worklet';
  if (value === 'always') return 1;
  if (value === 'never') return 2;
  return 0;
}

function startTimestamp(): number {
  'worklet';
  if (!NEEDS_START_STAMP) return Number.NaN;
  const runtime = globalThis as {
    __frameTimestamp?: number;
    _getAnimationTimestamp?: () => number;
  };
  return (
    runtime.__frameTimestamp ||
    (typeof runtime._getAnimationTimestamp === 'function'
      ? runtime._getAnimationTimestamp()
      : Number.NaN)
  );
}

function animationIsValid(animation: SmoothClipAnimation): boolean {
  'worklet';
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
  const mass = animation.mass ?? DEFAULT_MASS;
  const stiffness = animation.stiffness ?? DEFAULT_STIFFNESS;
  const damping = animation.damping ?? DEFAULT_DAMPING;
  const velocity = animation.velocity ?? 0;
  const energyThreshold = animation.energyThreshold ?? DEFAULT_ENERGY_THRESHOLD;
  return (
    [mass, stiffness, damping, velocity, energyThreshold].every(
      Number.isFinite
    ) &&
    mass > 0 &&
    stiffness > 0 &&
    damping >= 0 &&
    energyThreshold > 0
  );
}

function validCompletionTag(completionTag: number): boolean {
  'worklet';
  return (
    Number.isInteger(completionTag) &&
    completionTag >= 0 &&
    completionTag <= 0x7fffffff
  );
}

function validInternalCompletionTag(completionTag: number): boolean {
  'worklet';
  return (
    Number.isInteger(completionTag) &&
    completionTag >= -0x7fffffff &&
    completionTag <= 0x7fffffff
  );
}

function animateGroupOnUI(
  controllerId: number,
  entries: readonly SmoothClipGroupTarget[],
  animation: SmoothClipAnimation,
  completionTag: number,
  allowInternalCompletionTag = false
): SmoothClipRunHandle | null {
  'worklet';
  const completionTagIsValid = allowInternalCompletionTag
    ? validInternalCompletionTag(completionTag)
    : validCompletionTag(completionTag);
  if (!animationIsValid(animation) || !completionTagIsValid) {
    return null;
  }
  let internals: readonly InternalSmoothClipRef[];
  try {
    internals = validatedRefs(entries.map((entry) => entry.clip));
  } catch {
    return null;
  }
  const packet: number[] = [];
  for (let index = 0; index < entries.length; index += 1) {
    const entry = entries[index];
    const target =
      entry === undefined ? null : canonicalizeClipPresentation(entry.target);
    if (entry === undefined || target === null) return null;
    packet.push(internals[index]?.id ?? 0, 0);
    // Fixed native packets retain a start slot. With hasFrom=0 its contents
    // are ignored; duplicating the target avoids a second sentinel format.
    appendPresentationPacket(packet, target);
    appendPresentationPacket(packet, target);
  }
  if (packet.length !== entries.length * MOTION_ENTRY_STRIDE) return null;

  const timestamp = startTimestamp();
  let id: number;
  if (animation.type === 'timing') {
    const [x1, y1, x2, y2] = animation.controlPoints;
    id = animateTimingGroupHostFunction(
      controllerId,
      packet,
      animation.duration,
      x1,
      y1,
      x2,
      y2,
      reduceMotionCode(animation.reduceMotion),
      completionTag,
      timestamp
    );
  } else {
    id = animateSpringGroupHostFunction(
      controllerId,
      packet,
      animation.mass ?? DEFAULT_MASS,
      animation.stiffness ?? DEFAULT_STIFFNESS,
      animation.damping ?? DEFAULT_DAMPING,
      animation.velocity ?? 0,
      animation.energyThreshold ?? DEFAULT_ENERGY_THRESHOLD,
      reduceMotionCode(animation.reduceMotion),
      completionTag,
      timestamp
    );
  }
  if (id <= 0) return null;
  return {
    controllerId,
    id,
    refs: entries.map((entry) => entry.clip),
  } as unknown as InternalRunHandle;
}

function cancelGroupOnUI(
  controllerId: number,
  handle: SmoothClipRunHandle
): readonly SmoothClipGroupSnapshot[] {
  'worklet';
  const internal = handle as InternalRunHandle;
  if (
    internal.controllerId !== controllerId ||
    !Number.isInteger(internal.id) ||
    internal.id <= 0 ||
    !Array.isArray(internal.refs)
  ) {
    return [];
  }
  let internals: readonly InternalSmoothClipRef[];
  try {
    internals = validatedRefs(internal.refs);
  } catch {
    return [];
  }
  const values = cancelAnimationGroupHostFunction(internal.id, 0);
  if (values.length > 0) {
    return snapshotsFromPacket(internal.refs, values);
  }
  const snapshots = snapshotGroupHostFunction(
    internals.map((internalRefValue) => internalRefValue.id)
  );
  return snapshots.length === 0
    ? []
    : snapshotsFromPacket(internal.refs, snapshots);
}

function validReactEntries(entries: readonly SmoothClipGroupTarget[]): boolean {
  if (entries.length === 0) return false;
  const seen = new Set<number>();
  for (const entry of entries) {
    const ref = unwrapSmoothClipRef(entry.clip);
    if (
      ref === undefined ||
      seen.has(ref.id) ||
      canonicalizeClipPresentation(entry.target) === null
    ) {
      return false;
    }
    seen.add(ref.id);
  }
  return true;
}

function settleRun(run: PendingRun, finished: boolean): void {
  if (run.settled) return;
  run.settled = true;
  run.resolve(finished);
}

function registerNativeGroupRun(
  controllerId: number,
  clientRunId: number,
  groupId: number
): void {
  const run = clientRuns.get(clientRunId);
  clientRuns.delete(clientRunId);
  if (!run) return;
  run.resolveNativeId(groupId);
  const state = groupStates.get(controllerId);
  if (!state || groupId <= 0) {
    settleRun(run, false);
    state?.callbackRef.current?.({ finished: false });
    return;
  }
  state.runs.set(groupId, run);
  const deferred = state.deferredCompletions.get(groupId);
  if (deferred !== undefined) {
    state.deferredCompletions.delete(groupId);
    handleNativeGroupCompletion(
      controllerId,
      groupId,
      deferred.completionTag,
      deferred.finished,
      deferred.snapshots
    );
  }
}

function handleNativeGroupCompletion(
  controllerId: number,
  groupId: number,
  completionTag: number,
  finished: boolean,
  values: readonly number[]
): void {
  const state = groupStates.get(controllerId);
  if (!state || state.deliveredCompletions.has(groupId)) return;
  const run = state.runs.get(groupId);
  if (!run) {
    // Non-negative tags belong to UI-runtime runs, which deliberately have no
    // Promise registry on React. Negative tags are private correlation keys
    // for React runs and may arrive before scheduleOnRN registers the run.
    if (completionTag >= 0) {
      state.deliveredCompletions.add(groupId);
      state.callbackRef.current?.({
        finished,
        ...(completionTag > 0 ? { completionTag } : {}),
      });
      return;
    }
    state.deferredCompletions.set(groupId, {
      completionTag,
      finished,
      snapshots: values,
    });
    return;
  }
  state.deliveredCompletions.add(groupId);
  state.runs.delete(groupId);
  settleRun(run, finished);
  state.callbackRef.current?.({
    finished,
    ...(completionTag > 0 ? { completionTag } : {}),
  });
}

function cancelRegisteredRun(
  controllerId: number,
  groupId: number,
  refs: readonly SmoothClipRef[]
): void {
  scheduleOnUI(
    (ownerId: number, id: number, clips: readonly SmoothClipRef[]) => {
      'worklet';
      cancelGroupOnUI(ownerId, {
        controllerId: ownerId,
        id,
        refs: clips,
      } as unknown as InternalRunHandle);
    },
    controllerId,
    groupId,
    refs
  );
}

export function useSmoothClipGroup(
  options: SmoothClipGroupOptions = {}
): SmoothClipGroup {
  const controllerIdRef = useRef(0);
  const groupRef = useRef<SmoothClipGroup | null>(null);
  const callbackRef = useRef(options.onAnimationComplete);
  callbackRef.current = options.onAnimationComplete;
  if (controllerIdRef.current === 0) {
    controllerIdRef.current = allocateSmoothClipId();
  }
  const controllerId = controllerIdRef.current;

  if (groupRef.current === null) {
    groupRef.current = {
      ui: {
        setFrames(entries) {
          'worklet';
          setFramesOnUI(entries);
        },
        beginInteraction(refs) {
          'worklet';
          return beginGroupOnUI(refs);
        },
        animateTo(entries, animation, completionTag = 0) {
          'worklet';
          return animateGroupOnUI(
            controllerId,
            entries,
            animation,
            completionTag
          );
        },
        cancel(run) {
          'worklet';
          return cancelGroupOnUI(controllerId, run);
        },
      },
      react: {
        animateTo(entries, animation): SmoothClipReactRun {
          if (!validReactEntries(entries) || !animationIsValid(animation)) {
            callbackRef.current?.({ finished: false });
            return {
              finished: Promise.resolve(false),
              cancel() {},
            };
          }
          let resolve!: (finished: boolean) => void;
          let resolveNativeId!: (id: number) => void;
          const finished = new Promise<boolean>((accept) => {
            resolve = accept;
          });
          const nativeId = new Promise<number>((accept) => {
            resolveNativeId = accept;
          });
          const run: PendingRun = {
            controllerId,
            settled: false,
            cancelRequested: false,
            refs: entries.map((entry) => entry.clip),
            resolve,
            resolveNativeId,
            nativeId,
          };
          nextClientRunId = (nextClientRunId % 0x7ffffffe) + 1;
          const clientRunId = nextClientRunId;
          clientRuns.set(clientRunId, run);
          scheduleOnUI(
            (
              id: number,
              motionEntries: readonly SmoothClipGroupTarget[],
              spec: SmoothClipAnimation,
              pendingRunId: number
            ) => {
              'worklet';
              const handle = animateGroupOnUI(
                id,
                motionEntries,
                spec,
                -pendingRunId,
                true
              );
              scheduleOnRN(
                registerNativeGroupRun,
                id,
                pendingRunId,
                (handle as InternalRunHandle | null)?.id ?? 0
              );
            },
            controllerId,
            entries,
            animation,
            clientRunId
          );
          return {
            finished,
            cancel() {
              if (run.settled || run.cancelRequested) return;
              run.cancelRequested = true;
              nativeId.then((groupId) => {
                if (groupId > 0 && !run.settled) {
                  cancelRegisteredRun(run.controllerId, groupId, run.refs);
                }
              });
            },
          };
        },
      },
    };
  }

  useEffect(() => {
    const state: GroupState = {
      callbackRef,
      runs: new Map(),
      deferredCompletions: new Map(),
      deliveredCompletions: new Set(),
    };
    groupStates.set(controllerId, state);
    const unsubscribe = subscribeGroupCompletion(
      controllerId,
      ({ groupId, completionTag, finished, snapshots }) => {
        handleNativeGroupCompletion(
          controllerId,
          groupId,
          completionTag,
          finished,
          snapshots
        );
      }
    );
    return () => {
      unsubscribe();
      if (groupStates.get(controllerId) === state) {
        groupStates.delete(controllerId);
      }
      for (const run of state.runs.values()) settleRun(run, false);
      state.runs.clear();
      for (const [clientRunId, run] of clientRuns) {
        if (run.controllerId !== controllerId) continue;
        clientRuns.delete(clientRunId);
        run.resolveNativeId(0);
        settleRun(run, false);
      }
    };
  }, [controllerId]);

  return groupRef.current;
}
