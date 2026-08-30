import { useEffect, useRef } from 'react';
import {
  cancelAnimation as cancelReanimatedAnimation,
  Easing,
  makeMutable,
  ReduceMotion,
  useSharedValue,
  withSpring,
  withTiming,
  type SharedValue,
} from 'react-native-reanimated';
import { isRNRuntime, scheduleOnRN, scheduleOnUI } from 'react-native-worklets';
import type { SmoothClipDriver, SmoothClipDriverHandle } from './driverTypes';
import { allocateFallbackAnimationId } from './fallbackAnimationId';
import type {
  SmoothClipBatchEntry,
  SmoothClipGroupCancelBehavior,
  SmoothClipGroupDriver,
  SmoothClipGroupDriverOptions,
  SmoothClipGroupKeyframeAnimation,
  SmoothClipGroupKeyframeEntry,
  SmoothClipGroupMotionAnimation,
  SmoothClipGroupMotionEntry,
  SmoothClipGroupSnapshot,
} from './groupDriverTypes';
import {
  canonicalizeClipPresentation,
  clipPresentationEquals,
  type CanonicalSmoothClipPresentation,
} from './geometry';

const INTERACTIVE = 0;
// Individual fallback animations use ownership 1. A distinct owner code
// keeps the ownership channel explicit even though both paths now allocate
// from one process-global animation-id namespace.
const GROUP_OWNED = 2;

function isDisallowedReactRuntime(): boolean {
  'worklet';
  // Web deliberately runs worklets on the browser runtime, where document is
  // present. Native keeps the strict UI-runtime-only contract.
  return (
    isRNRuntime() &&
    typeof (globalThis as { document?: unknown }).document === 'undefined'
  );
}

type CanonicalGroupFrame = Readonly<{
  offset: number;
  presentation: CanonicalSmoothClipPresentation;
}>;

type ActiveParticipant = Readonly<{
  driver: SmoothClipDriver;
  handle: SmoothClipDriverHandle;
  from: CanonicalSmoothClipPresentation;
  target: CanonicalSmoothClipPresentation;
  frames: readonly CanonicalGroupFrame[];
}>;

type GroupDriverState = {
  callbackRef: {
    current: SmoothClipGroupDriverOptions['onAnimationComplete'];
  };
  completionDeferrals: number;
  deferredCompletions: Array<Readonly<{ groupId: number; finished: boolean }>>;
};

const groupDriverStates = new Map<number, GroupDriverState>();
let nextGroupControllerId = -1;

type PendingGroupRequest = Readonly<{
  resolve(value: unknown): void;
  reject(error: Error): void;
  teardownValue?: unknown;
  releasesCompletions?: boolean;
}>;

const pendingGroupRequests = new Map<number, PendingGroupRequest>();
const requestIdsByController = new Map<number, Set<number>>();
let nextGroupRequestId = 0;

function allocateGroupControllerId(): number {
  const controllerId = nextGroupControllerId;
  nextGroupControllerId -= 1;
  if (!Number.isSafeInteger(nextGroupControllerId)) nextGroupControllerId = -1;
  return controllerId;
}

function deliverGroupCompletion(
  controllerId: number,
  groupId: number,
  finished: boolean
): void {
  const state = groupDriverStates.get(controllerId);
  if (state === undefined) return;
  const result = { groupId, finished };
  if (state.completionDeferrals > 0) {
    state.deferredCompletions.push(result);
    return;
  }
  state.callbackRef.current?.(result);
}

function deferGroupCompletions(controllerId: number): void {
  const state = groupDriverStates.get(controllerId);
  if (state) state.completionDeferrals += 1;
}

function releaseGroupCompletions(controllerId: number): void {
  const state = groupDriverStates.get(controllerId);
  if (!state || state.completionDeferrals === 0) return;
  state.completionDeferrals -= 1;
  if (state.completionDeferrals !== 0) return;
  const deferred = state.deferredCompletions.splice(0);
  for (const result of deferred) state.callbackRef.current?.(result);
}

function createGroupRequest<T>(
  controllerId: number,
  teardownResolution?: Readonly<{ value: unknown }>,
  deferCompletions = false
): Readonly<{ requestId: number; promise: Promise<T> }> {
  nextGroupRequestId = (nextGroupRequestId % 0x7ffffffe) + 1;
  const requestId = nextGroupRequestId;
  let resolveRequest!: (value: T) => void;
  let rejectRequest!: (error: Error) => void;
  const promise = new Promise<T>((resolve, reject) => {
    resolveRequest = resolve;
    rejectRequest = reject;
  });
  pendingGroupRequests.set(requestId, {
    resolve: resolveRequest as (value: unknown) => void,
    reject: rejectRequest,
    ...(teardownResolution === undefined
      ? {}
      : { teardownValue: teardownResolution.value }),
    ...(deferCompletions ? { releasesCompletions: true } : {}),
  });
  const ids = requestIdsByController.get(controllerId) ?? new Set<number>();
  ids.add(requestId);
  requestIdsByController.set(controllerId, ids);
  if (deferCompletions) deferGroupCompletions(controllerId);
  return { requestId, promise };
}

function settleGroupRequest(
  controllerId: number,
  requestId: number,
  succeeded: boolean,
  value: unknown,
  message: string
): void {
  const request = pendingGroupRequests.get(requestId);
  pendingGroupRequests.delete(requestId);
  const ids = requestIdsByController.get(controllerId);
  ids?.delete(requestId);
  if (ids?.size === 0) requestIdsByController.delete(controllerId);
  if (request === undefined) return;
  if (succeeded) request.resolve(value);
  else request.reject(new Error(message));
  if (request.releasesCompletions) {
    // One turn resolves the Promise; the second lets reactions already
    // attached to that Promise observe settlement before callbacks run.
    queueMicrotask(() => {
      queueMicrotask(() => releaseGroupCompletions(controllerId));
    });
  }
}

function rejectGroupRequests(controllerId: number): void {
  const ids = requestIdsByController.get(controllerId);
  if (ids !== undefined) {
    for (const requestId of ids) {
      const request = pendingGroupRequests.get(requestId);
      pendingGroupRequests.delete(requestId);
      if (request === undefined) continue;
      if ('teardownValue' in request) request.resolve(request.teardownValue);
      else
        request.reject(
          new Error('[SmoothClipView] Group driver was destroyed.')
        );
    }
    requestIdsByController.delete(controllerId);
  }
  const state = groupDriverStates.get(controllerId);
  if (state) state.completionDeferrals = 0;
}

function detachGroupDriverState(
  controllerId: number,
  state: GroupDriverState
): void {
  state.completionDeferrals = 0;
  const deferred = state.deferredCompletions.splice(0);
  if (groupDriverStates.get(controllerId) === state) {
    groupDriverStates.delete(controllerId);
  }
  if (deferred.length === 0) return;
  queueMicrotask(() => {
    queueMicrotask(() => {
      for (const result of deferred) state.callbackRef.current?.(result);
    });
  });
}

function errorMessage(error: unknown): string {
  'worklet';
  return error instanceof Error
    ? error.message
    : '[SmoothClipView] Group operation failed.';
}

function fail(message: string): never {
  'worklet';
  throw new Error(`[SmoothClipView] ${message}`);
}

function toReanimatedReduceMotion(
  value: SmoothClipGroupDriverOptions['reduceMotion']
) {
  switch (value) {
    case 'always':
      return ReduceMotion.Always;
    case 'never':
      return ReduceMotion.Never;
    default:
      return ReduceMotion.System;
  }
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

function presentationAtProgress(
  participant: ActiveParticipant,
  progress: number
): CanonicalSmoothClipPresentation {
  'worklet';
  const { frames } = participant;
  if (frames.length < 2) {
    return interpolatePresentation(
      participant.from,
      participant.target,
      progress
    );
  }

  let upperIndex = 1;
  while (
    upperIndex < frames.length - 1 &&
    progress > (frames[upperIndex]?.offset ?? 1)
  ) {
    upperIndex += 1;
  }
  const lower = frames[upperIndex - 1];
  const upper = frames[upperIndex];
  if (lower === undefined || upper === undefined) return participant.target;
  const span = upper.offset - lower.offset;
  const localProgress = span <= 0 ? 1 : (progress - lower.offset) / span;
  return interpolatePresentation(
    lower.presentation,
    upper.presentation,
    Math.min(1, Math.max(0, localProgress))
  );
}

function validSuspensionPolicy(value: unknown): boolean {
  'worklet';
  return value === undefined || value === 'pause' || value === 'finish';
}

function motionAnimationIsFinite(
  animation: SmoothClipGroupMotionAnimation
): boolean {
  'worklet';
  if (!validSuspensionPolicy(animation.suspensionPolicy)) return false;
  if (animation.type === 'timing') {
    const [x1, , x2] = animation.controlPoints;
    return (
      Number.isFinite(animation.duration) &&
      animation.duration >= 0 &&
      animation.controlPoints.length === 4 &&
      animation.controlPoints.every(Number.isFinite) &&
      x1 >= 0 &&
      x1 <= 1 &&
      x2 >= 0 &&
      x2 <= 1
    );
  }
  if (animation.type !== 'spring') return false;
  const mass = animation.mass ?? 1;
  const stiffness = animation.stiffness ?? 100;
  const damping = animation.damping ?? 10;
  return (
    [
      mass,
      stiffness,
      damping,
      animation.initialVelocity === 'inherit'
        ? 0
        : (animation.initialVelocity ?? 0),
    ].every(Number.isFinite) &&
    mass > 0 &&
    stiffness > 0 &&
    damping >= 0
  );
}

function keyframeAnimationIsFinite(
  animation: SmoothClipGroupKeyframeAnimation
): boolean {
  'worklet';
  return (
    animation.type === 'keyframes' &&
    Number.isFinite(animation.duration) &&
    animation.duration >= 0 &&
    validSuspensionPolicy(animation.suspensionPolicy)
  );
}

function finiteHandle(driver: SmoothClipDriver): SmoothClipDriverHandle | null {
  'worklet';
  const handle = driver.__smoothClipHandle;
  if (
    driver.kind !== 'hybrid' ||
    handle === undefined ||
    !Number.isSafeInteger(handle.driverId) ||
    handle.driverId <= 0 ||
    !Number.isFinite(handle.disposed.value) ||
    !Number.isFinite(handle.ownership.value) ||
    !Number.isFinite(handle.activeAnimationId.value)
  ) {
    return null;
  }
  return handle;
}

function containsDriverId(
  handles: readonly SmoothClipDriverHandle[],
  driverId: number
): boolean {
  'worklet';
  for (const handle of handles) {
    if (handle.driverId === driverId) return true;
  }
  return false;
}

function validateDrivers(
  drivers: readonly SmoothClipDriver[]
): readonly SmoothClipGroupSnapshot[] | null {
  'worklet';
  if (!Array.isArray(drivers) || drivers.length === 0) return null;
  const handles: SmoothClipDriverHandle[] = [];
  const snapshots: SmoothClipGroupSnapshot[] = [];
  for (const driver of drivers) {
    const handle = finiteHandle(driver);
    if (
      handle === null ||
      containsDriverId(handles, handle.driverId) ||
      handle.disposed.value !== 0
    ) {
      return null;
    }
    const presentation = canonicalizeClipPresentation(
      handle.presentation.value
    );
    if (presentation === null) return null;
    handles.push(handle);
    snapshots.push({
      driver,
      presentation,
      ready: (handle.ready?.value ?? 1) === 1,
    });
  }
  return snapshots;
}

function validateBatch(entries: readonly SmoothClipBatchEntry[]):
  | readonly Readonly<{
      driver: SmoothClipDriver;
      handle: SmoothClipDriverHandle;
      presentation: CanonicalSmoothClipPresentation;
    }>[]
  | null {
  'worklet';
  if (!Array.isArray(entries) || entries.length === 0) return null;
  const handles: SmoothClipDriverHandle[] = [];
  const result: {
    driver: SmoothClipDriver;
    handle: SmoothClipDriverHandle;
    presentation: CanonicalSmoothClipPresentation;
  }[] = [];
  for (const entry of entries) {
    const handle = finiteHandle(entry.driver);
    const presentation = canonicalizeClipPresentation(entry.presentation);
    if (
      handle === null ||
      handle.disposed.value !== 0 ||
      presentation === null ||
      containsDriverId(handles, handle.driverId)
    ) {
      return null;
    }
    handles.push(handle);
    result.push({ driver: entry.driver, handle, presentation });
  }
  return result;
}

function validateKeyframes(
  entry: SmoothClipGroupKeyframeEntry,
  from: CanonicalSmoothClipPresentation,
  target: CanonicalSmoothClipPresentation
): readonly CanonicalGroupFrame[] | null {
  'worklet';
  if (!Array.isArray(entry.frames) || entry.frames.length < 2) return null;
  const frames: CanonicalGroupFrame[] = [];
  let previousOffset = -1;
  for (const frame of entry.frames) {
    const canonical = canonicalizeClipPresentation(frame.presentation);
    const presentation =
      frames.length === 0 && entry.from === undefined ? from : canonical;
    if (
      !Number.isFinite(frame.offset) ||
      frame.offset < 0 ||
      frame.offset > 1 ||
      frame.offset <= previousOffset ||
      canonical === null ||
      presentation === null ||
      presentation.clip.curve !== from.clip.curve
    ) {
      return null;
    }
    previousOffset = frame.offset;
    frames.push({ offset: frame.offset, presentation });
  }
  if (
    frames[0]?.offset !== 0 ||
    previousOffset !== 1 ||
    (entry.from !== undefined &&
      !clipPresentationEquals(frames[0]?.presentation ?? null, from)) ||
    !clipPresentationEquals(
      frames[frames.length - 1]?.presentation ?? null,
      target
    )
  ) {
    return null;
  }
  return frames;
}

function validateMotionEntries(
  entries: readonly (
    SmoothClipGroupMotionEntry | SmoothClipGroupKeyframeEntry
  )[],
  keyframed: boolean
): readonly ActiveParticipant[] | null {
  'worklet';
  if (!Array.isArray(entries) || entries.length === 0) return null;
  const handles: SmoothClipDriverHandle[] = [];
  const participants: ActiveParticipant[] = [];
  for (const entry of entries) {
    const handle = finiteHandle(entry.driver);
    const current =
      handle === null
        ? null
        : canonicalizeClipPresentation(handle.presentation.value);
    const from =
      entry.from === undefined
        ? current
        : canonicalizeClipPresentation(entry.from);
    const target = canonicalizeClipPresentation(entry.target);
    if (
      handle === null ||
      handle.disposed.value !== 0 ||
      current === null ||
      from === null ||
      target === null ||
      containsDriverId(handles, handle.driverId) ||
      from.clip.curve !== target.clip.curve
    ) {
      return null;
    }
    let frames: readonly CanonicalGroupFrame[] = [];
    if (keyframed) {
      if (!('frames' in entry)) return null;
      const canonicalFrames = validateKeyframes(entry, from, target);
      if (canonicalFrames === null) return null;
      frames = canonicalFrames;
    }
    handles.push(handle);
    participants.push({
      driver: entry.driver,
      handle,
      from,
      target,
      frames,
    });
  }
  return participants;
}

function springScaleIsProvablyPositive(
  participants: readonly ActiveParticipant[],
  animation: Extract<SmoothClipGroupMotionAnimation, { type: 'spring' }>
): boolean {
  'worklet';
  let changesScale = false;
  for (const participant of participants) {
    if (participant.from.contentScale !== participant.target.contentScale) {
      changesScale = true;
      break;
    }
  }
  if (!changesScale) return true;

  // Only a zero-velocity critically/over-damped unit-step response is
  // provably monotonic. Other scale-changing springs may cross zero and must
  // be compiled to positive keyframes by the caller.
  const mass = animation.mass ?? 1;
  const stiffness = animation.stiffness ?? 100;
  const damping = animation.damping ?? 10;
  return (
    animation.initialVelocity === 0 && damping * damping >= 4 * mass * stiffness
  );
}

function participantsIntersect(
  participants: readonly ActiveParticipant[],
  driverIds: readonly number[]
): boolean {
  'worklet';
  for (const participant of participants) {
    for (const driverId of driverIds) {
      if (participant.handle.driverId === driverId) return true;
    }
  }
  return false;
}

type FallbackGroupAnimation =
  | Readonly<{
      type: 'timing';
      duration: number;
      controlPoints: readonly [number, number, number, number];
    }>
  | Readonly<{
      type: 'spring';
      mass: number;
      stiffness: number;
      damping: number;
      initialVelocity: number;
    }>
  | Readonly<{ type: 'keyframes'; duration: number }>;

type FallbackGroupRecord = {
  controllerId: number;
  groupId: number;
  participants: readonly ActiveParticipant[];
  animation: FallbackGroupAnimation;
  progress: SharedValue<number>;
  reduceMotion: ReduceMotion;
  suspensionPolicy: 'pause' | 'finish';
  /** Whether the readiness latch has opened at least once. */
  started: boolean;
  running: boolean;
};

type FallbackGroupRuntimeGlobal = typeof globalThis & {
  __smoothClipFallbackGroups?: Record<string, FallbackGroupRecord>;
};

function fallbackGroupRecords(): Record<string, FallbackGroupRecord> {
  'worklet';
  const runtime = globalThis as FallbackGroupRuntimeGlobal;
  runtime.__smoothClipFallbackGroups ??= {};
  return runtime.__smoothClipFallbackGroups;
}

function participantReady(participant: ActiveParticipant): boolean {
  'worklet';
  return (
    participant.handle.disposed.value === 0 &&
    (participant.handle.ready?.value ?? 1) === 1
  );
}

function fallbackGroupIsOwned(record: FallbackGroupRecord): boolean {
  'worklet';
  for (const participant of record.participants) {
    const { handle } = participant;
    if (
      handle.disposed.value !== 0 ||
      handle.ownership.value !== GROUP_OWNED ||
      handle.activeAnimationId.value !== record.groupId
    ) {
      return false;
    }
  }
  return true;
}

function fallbackGroupIsReady(record: FallbackGroupRecord): boolean {
  'worklet';
  for (const participant of record.participants) {
    if (!participantReady(participant)) return false;
  }
  return true;
}

function removeFallbackGroupListeners(record: FallbackGroupRecord): void {
  'worklet';
  record.progress.removeListener(record.groupId);
  for (const participant of record.participants) {
    const { handle } = participant;
    handle.activeAnimationId.removeListener(record.groupId);
    handle.ownership.removeListener(record.groupId);
    handle.disposed.removeListener(record.groupId);
    handle.ready?.removeListener(record.groupId);
  }
}

function snapshotsForFallbackRecord(
  record: FallbackGroupRecord
): readonly SmoothClipGroupSnapshot[] {
  'worklet';
  const snapshots: SmoothClipGroupSnapshot[] = [];
  for (const participant of record.participants) {
    snapshots.push({
      driver: participant.driver,
      presentation:
        canonicalizeClipPresentation(participant.handle.presentation.value) ??
        participant.from,
      ready: participantReady(participant),
    });
  }
  return snapshots;
}

function settleFallbackGroup(
  groupId: number,
  behavior: SmoothClipGroupCancelBehavior,
  requestedFinished: boolean
): readonly SmoothClipGroupSnapshot[] {
  'worklet';
  const records = fallbackGroupRecords();
  const record = records[String(groupId)];
  if (record === undefined) return [];
  const allOwned = fallbackGroupIsOwned(record);
  const finished = requestedFinished && allOwned;
  const finishAtTarget = behavior === 'finish' && finished;

  delete records[String(groupId)];
  removeFallbackGroupListeners(record);
  record.running = false;
  cancelReanimatedAnimation(record.progress);
  for (const participant of record.participants) {
    const { handle } = participant;
    if (
      handle.ownership.value === GROUP_OWNED &&
      handle.activeAnimationId.value === groupId
    ) {
      if (finishAtTarget) handle.presentation.value = participant.target;
      handle.activeAnimationId.value = 0;
      handle.ownership.value = INTERACTIVE;
    }
  }
  const snapshots = snapshotsForFallbackRecord(record);
  scheduleOnRN(deliverGroupCompletion, record.controllerId, groupId, finished);
  return snapshots;
}

function startFallbackGroup(record: FallbackGroupRecord): void {
  'worklet';
  if (record.running) return;
  record.started = true;
  record.running = true;
  const groupId = record.groupId;
  const onComplete = (animationFinished?: boolean) => {
    'worklet';
    const current = fallbackGroupRecords()[String(groupId)];
    if (current !== record || !record.running) return;
    settleFallbackGroup(
      groupId,
      animationFinished === true ? 'finish' : 'freeze',
      animationFinished === true
    );
  };
  if (record.animation.type === 'timing') {
    const [x1, y1, x2, y2] = record.animation.controlPoints;
    const progress = Math.min(1, Math.max(0, record.progress.value));
    record.progress.value = withTiming(
      1,
      {
        duration: Math.max(0, record.animation.duration * (1 - progress)),
        easing: Easing.bezier(x1, y1, x2, y2),
        reduceMotion: record.reduceMotion,
      },
      onComplete
    );
  } else if (record.animation.type === 'spring') {
    record.progress.value = withSpring(
      1,
      {
        damping: record.animation.damping,
        mass: record.animation.mass,
        reduceMotion: record.reduceMotion,
        stiffness: record.animation.stiffness,
        velocity: record.animation.initialVelocity,
      },
      onComplete
    );
  } else {
    const progress = Math.min(1, Math.max(0, record.progress.value));
    record.progress.value = withTiming(
      1,
      {
        duration: Math.max(0, record.animation.duration * (1 - progress)),
        easing: Easing.linear,
        reduceMotion: record.reduceMotion,
      },
      onComplete
    );
  }
}

function reconcileFallbackGroup(groupId: number): void {
  'worklet';
  const record = fallbackGroupRecords()[String(groupId)];
  if (record === undefined) return;
  if (!fallbackGroupIsOwned(record)) {
    settleFallbackGroup(groupId, 'freeze', false);
    return;
  }
  if (!fallbackGroupIsReady(record)) {
    // `finish` only applies after a group that has started loses readiness.
    // Every initially-unready group must remain latched until all participants
    // become ready, irrespective of its suspension policy.
    if (record.started && record.suspensionPolicy === 'finish') {
      settleFallbackGroup(groupId, 'finish', true);
    } else if (record.running) {
      record.running = false;
      cancelReanimatedAnimation(record.progress);
    }
    return;
  }
  startFallbackGroup(record);
}

// Reanimated's production web transform rewrites worklet declarations to const
// initializers. Keep this after reconcileFallbackGroup so its captured helper is
// initialized before this worklet is materialized.
function updateFallbackGroupProgress(groupId: number, progress: number): void {
  'worklet';
  const record = fallbackGroupRecords()[String(groupId)];
  if (record === undefined || !record.running) return;
  if (!Number.isFinite(progress) || !fallbackGroupIsOwned(record)) {
    settleFallbackGroup(groupId, 'freeze', false);
    return;
  }
  if (!fallbackGroupIsReady(record)) {
    reconcileFallbackGroup(groupId);
    return;
  }
  const resolvedProgress =
    record.animation.type === 'spring'
      ? progress
      : Math.min(1, Math.max(0, progress));
  for (const participant of record.participants) {
    participant.handle.presentation.value = presentationAtProgress(
      participant,
      resolvedProgress
    );
  }
}

function attachFallbackGroupListeners(record: FallbackGroupRecord): void {
  'worklet';
  const { groupId } = record;
  record.progress.addListener(groupId, (progress) => {
    'worklet';
    updateFallbackGroupProgress(groupId, progress);
  });
  for (const participant of record.participants) {
    const reconcile = () => {
      'worklet';
      reconcileFallbackGroup(groupId);
    };
    participant.handle.activeAnimationId.addListener(groupId, reconcile);
    participant.handle.ownership.addListener(groupId, reconcile);
    participant.handle.disposed.addListener(groupId, reconcile);
    participant.handle.ready?.addListener(groupId, reconcile);
  }
}

function settleIntersectingFallbackGroups(driverIds: readonly number[]): void {
  'worklet';
  const records = fallbackGroupRecords();
  const groupIds: number[] = [];
  for (const key of Object.keys(records)) {
    const record = records[key];
    if (record && participantsIntersect(record.participants, driverIds)) {
      groupIds.push(record.groupId);
    }
  }
  for (const groupId of groupIds) {
    settleFallbackGroup(groupId, 'freeze', false);
  }
}

function copyFallbackAnimation(
  animation: SmoothClipGroupMotionAnimation | SmoothClipGroupKeyframeAnimation
): FallbackGroupAnimation {
  'worklet';
  if (animation.type === 'timing') {
    return {
      type: 'timing',
      duration: animation.duration,
      controlPoints: [...animation.controlPoints] as [
        number,
        number,
        number,
        number,
      ],
    };
  }
  if (animation.type === 'spring') {
    return {
      type: 'spring',
      mass: animation.mass ?? 1,
      stiffness: animation.stiffness ?? 100,
      damping: animation.damping ?? 10,
      initialVelocity:
        typeof animation.initialVelocity === 'number'
          ? animation.initialVelocity
          : 0,
    };
  }
  return { type: 'keyframes', duration: animation.duration };
}

export function useSmoothClipGroupDriver(
  options: SmoothClipGroupDriverOptions = {}
): SmoothClipGroupDriver {
  const controllerIdRef = useRef<number | null>(null);
  if (controllerIdRef.current === null) {
    controllerIdRef.current = allocateGroupControllerId();
  }
  const controllerId = controllerIdRef.current;
  const callbackRef = useRef(options.onAnimationComplete);
  callbackRef.current = options.onAnimationComplete;
  const stateRef = useRef<GroupDriverState | null>(null);
  if (stateRef.current === null) {
    stateRef.current = {
      callbackRef,
      completionDeferrals: 0,
      deferredCompletions: [],
    };
  }

  const disposed = useSharedValue(0);
  const driverRef = useRef<SmoothClipGroupDriver | null>(null);
  const reduceMotion = toReanimatedReduceMotion(options.reduceMotion);

  if (driverRef.current === null) {
    const snapshotOnUI = (
      drivers: readonly SmoothClipDriver[]
    ): readonly SmoothClipGroupSnapshot[] => {
      'worklet';
      if (disposed.value !== 0) return fail('Group driver was destroyed.');
      return (
        validateDrivers(drivers) ??
        fail(
          'Every group participant must be a live, unique SmoothClip driver.'
        )
      );
    };

    const beginOnUI = (
      drivers: readonly SmoothClipDriver[]
    ): readonly SmoothClipGroupSnapshot[] => {
      'worklet';
      if (disposed.value !== 0) return fail('Group driver was destroyed.');
      const snapshots =
        validateDrivers(drivers) ??
        fail(
          'Every group participant must be a live, unique SmoothClip driver.'
        );
      const driverIds = snapshots.map(
        (snapshot) => snapshot.driver.__smoothClipHandle?.driverId ?? 0
      );
      settleIntersectingFallbackGroups(driverIds);
      const result: SmoothClipGroupSnapshot[] = [];
      for (const snapshot of snapshots) {
        const handle = snapshot.driver.__smoothClipHandle;
        if (handle === undefined || handle.disposed.value !== 0) {
          return fail('A group participant became unavailable.');
        }
        const presentation = canonicalizeClipPresentation(
          snapshot.driver.ui.beginInteraction()
        );
        if (presentation === null) {
          return fail('A group participant returned an invalid presentation.');
        }
        result.push({
          driver: snapshot.driver,
          presentation,
          ready: (handle.ready?.value ?? 1) === 1,
        });
      }
      return result;
    };

    const setBatchOnUI = (entries: readonly SmoothClipBatchEntry[]): void => {
      'worklet';
      // A frame callback can be delivered once while React is tearing down its
      // sibling hooks on web. A stale void write has no result to report and
      // must not surface an uncaught exception after the group is disposed.
      if (disposed.value !== 0) return;
      const canonicalEntries = validateBatch(entries);
      if (canonicalEntries === null) {
        return fail('Every batch entry must be finite, live, and unique.');
      }
      const driverIds = canonicalEntries.map((entry) => entry.handle.driverId);
      settleIntersectingFallbackGroups(driverIds);
      for (const entry of canonicalEntries) {
        entry.driver.ui.set(entry.presentation);
      }
    };

    const animateOnUI = (
      entries: readonly (
        SmoothClipGroupMotionEntry | SmoothClipGroupKeyframeEntry
      )[],
      animation:
        SmoothClipGroupMotionAnimation | SmoothClipGroupKeyframeAnimation
    ): number => {
      'worklet';
      if (disposed.value !== 0) return fail('Group driver was destroyed.');
      const keyframed = animation.type === 'keyframes';
      const validAnimation = keyframed
        ? keyframeAnimationIsFinite(animation)
        : motionAnimationIsFinite(animation);
      const participants = validAnimation
        ? validateMotionEntries(entries, keyframed)
        : null;
      if (participants === null) {
        return fail('Group animation entries or configuration are invalid.');
      }
      if (
        animation.type === 'spring' &&
        !springScaleIsProvablyPositive(participants, animation)
      ) {
        return fail(
          'This scale-changing spring is not provably positive; compile it to keyframes.'
        );
      }
      const groupId = allocateFallbackAnimationId();
      settleIntersectingFallbackGroups(
        participants.map((participant) => participant.handle.driverId)
      );

      // The participant list and all canonical endpoints were copied during
      // validation. Later mutation of the caller's entry array cannot join,
      // remove, or retarget a running group.
      for (const participant of participants) {
        participant.driver.ui.beginInteraction();
        participant.driver.ui.set(participant.from);
        participant.handle.activeAnimationId.value = groupId;
        participant.handle.ownership.value = GROUP_OWNED;
      }
      const record: FallbackGroupRecord = {
        controllerId,
        groupId,
        participants,
        animation: copyFallbackAnimation(animation),
        progress: makeMutable(0),
        reduceMotion,
        suspensionPolicy: animation.suspensionPolicy ?? 'pause',
        started: false,
        running: false,
      };
      fallbackGroupRecords()[String(groupId)] = record;
      attachFallbackGroupListeners(record);
      reconcileFallbackGroup(groupId);
      return groupId;
    };

    const cancelOnUI = (
      groupId: number,
      behavior: SmoothClipGroupCancelBehavior = 'freeze'
    ): readonly SmoothClipGroupSnapshot[] => {
      'worklet';
      if (disposed.value !== 0) return fail('Group driver was destroyed.');
      if (!Number.isSafeInteger(groupId) || groupId <= 0) {
        return fail('A group ID must be a positive integer.');
      }
      if (behavior !== 'freeze' && behavior !== 'finish') {
        return fail('Group cancel behavior is invalid.');
      }
      const record = fallbackGroupRecords()[String(groupId)];
      if (record === undefined || record.controllerId !== controllerId)
        return [];
      return settleFallbackGroup(groupId, behavior, behavior === 'finish');
    };

    const ui = {
      beginInteraction(drivers: readonly SmoothClipDriver[]) {
        'worklet';
        if (isDisallowedReactRuntime())
          return fail(
            'group.ui methods must run on the UI runtime. Use group.react from React code.'
          );
        return beginOnUI(drivers);
      },
      snapshotCurrent(drivers: readonly SmoothClipDriver[]) {
        'worklet';
        if (isDisallowedReactRuntime())
          return fail(
            'group.ui methods must run on the UI runtime. Use group.react from React code.'
          );
        return snapshotOnUI(drivers);
      },
      setBatch(entries: readonly SmoothClipBatchEntry[]) {
        'worklet';
        if (isDisallowedReactRuntime())
          return fail(
            'group.ui methods must run on the UI runtime. Use group.react from React code.'
          );
        setBatchOnUI(entries);
      },
      animateTo(
        entries: readonly (
          SmoothClipGroupMotionEntry | SmoothClipGroupKeyframeEntry
        )[],
        animation:
          SmoothClipGroupMotionAnimation | SmoothClipGroupKeyframeAnimation
      ) {
        'worklet';
        if (isDisallowedReactRuntime())
          return fail(
            'group.ui methods must run on the UI runtime. Use group.react from React code.'
          );
        return animateOnUI(entries, animation);
      },
      cancel(
        groupId: number,
        behavior: SmoothClipGroupCancelBehavior = 'freeze'
      ) {
        'worklet';
        if (isDisallowedReactRuntime())
          return fail(
            'group.ui methods must run on the UI runtime. Use group.react from React code.'
          );
        return cancelOnUI(groupId, behavior);
      },
    } as SmoothClipGroupDriver['ui'];

    driverRef.current = {
      kind: 'group',
      ui,
      react: {
        beginInteraction(drivers) {
          const { requestId, promise } = createGroupRequest<
            readonly SmoothClipGroupSnapshot[]
          >(controllerId, undefined, true);
          scheduleOnUI(() => {
            'worklet';
            try {
              const result = beginOnUI(drivers);
              scheduleOnRN(
                settleGroupRequest,
                controllerId,
                requestId,
                true,
                result,
                ''
              );
            } catch (error) {
              scheduleOnRN(
                settleGroupRequest,
                controllerId,
                requestId,
                false,
                undefined,
                errorMessage(error)
              );
            }
          });
          return promise;
        },
        snapshotCurrent(drivers) {
          const { requestId, promise } =
            createGroupRequest<readonly SmoothClipGroupSnapshot[]>(
              controllerId
            );
          scheduleOnUI(() => {
            'worklet';
            try {
              const result = snapshotOnUI(drivers);
              scheduleOnRN(
                settleGroupRequest,
                controllerId,
                requestId,
                true,
                result,
                ''
              );
            } catch (error) {
              scheduleOnRN(
                settleGroupRequest,
                controllerId,
                requestId,
                false,
                undefined,
                errorMessage(error)
              );
            }
          });
          return promise;
        },
        setBatch(entries) {
          if (disposed.value !== 0) {
            return Promise.reject(
              new Error('[SmoothClipView] Group driver was destroyed.')
            );
          }
          const { requestId, promise } = createGroupRequest<void>(
            controllerId,
            {
              value: undefined,
            },
            true
          );
          scheduleOnUI(() => {
            'worklet';
            try {
              setBatchOnUI(entries);
              scheduleOnRN(
                settleGroupRequest,
                controllerId,
                requestId,
                true,
                undefined,
                ''
              );
            } catch (error) {
              scheduleOnRN(
                settleGroupRequest,
                controllerId,
                requestId,
                false,
                undefined,
                errorMessage(error)
              );
            }
          });
          return promise;
        },
        animateTo(entries, animation) {
          const { requestId, promise } = createGroupRequest<number>(
            controllerId,
            { value: 0 },
            true
          );
          scheduleOnUI(() => {
            'worklet';
            try {
              const result = animateOnUI(entries, animation);
              scheduleOnRN(
                settleGroupRequest,
                controllerId,
                requestId,
                true,
                result,
                ''
              );
            } catch (error) {
              scheduleOnRN(
                settleGroupRequest,
                controllerId,
                requestId,
                false,
                undefined,
                errorMessage(error)
              );
            }
          });
          return promise;
        },
        cancel(groupId, behavior = 'freeze') {
          const { requestId, promise } = createGroupRequest<
            readonly SmoothClipGroupSnapshot[]
          >(controllerId, undefined, true);
          scheduleOnUI(() => {
            'worklet';
            try {
              const result = cancelOnUI(groupId, behavior);
              scheduleOnRN(
                settleGroupRequest,
                controllerId,
                requestId,
                true,
                result,
                ''
              );
            } catch (error) {
              scheduleOnRN(
                settleGroupRequest,
                controllerId,
                requestId,
                false,
                undefined,
                errorMessage(error)
              );
            }
          });
          return promise;
        },
      },
    };
  }

  const groupDriver = driverRef.current;
  useEffect(() => {
    const state = stateRef.current;
    if (state === null) return undefined;
    disposed.value = 0;
    groupDriverStates.set(controllerId, state);
    return () => {
      disposed.value = 1;
      const groupIds: number[] = [];
      for (const key of Object.keys(fallbackGroupRecords())) {
        const record = fallbackGroupRecords()[key];
        if (record?.controllerId === controllerId)
          groupIds.push(record.groupId);
      }
      for (const groupId of groupIds) {
        settleFallbackGroup(groupId, 'freeze', false);
      }
      rejectGroupRequests(controllerId);
      detachGroupDriverState(controllerId, state);
    };
  }, [controllerId, disposed]);

  return groupDriver;
}
