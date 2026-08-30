import { useEffect, useRef } from 'react';
import { Platform } from 'react-native';
import { useSharedValue } from 'react-native-reanimated';
import { isRNRuntime, scheduleOnRN, scheduleOnUI } from 'react-native-worklets';
import NativeSmoothClipModule from './smoothClipNative';
import { getSmoothClipCapabilities } from './capabilities';
import { allocateDriverId } from './driverState';
import type { SmoothClipDriver, SmoothClipDriverHandle } from './driverTypes';
import type {
  SmoothClipBatchEntry,
  SmoothClipGroupAnimationResult,
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
const NATIVE = 1;
const PRESENTATION_STRIDE = 12;
const SNAPSHOT_STRIDE = 13;
const MOTION_ENTRY_STRIDE = 26;
const NEEDS_START_STAMP = Platform.OS === 'android';
const GROUPS_SUPPORTED = getSmoothClipCapabilities().groups;

type NativeGroupHostFunctions = Readonly<{
  beginGroupInteractionV2(driverIds: readonly number[]): readonly number[];
  snapshotGroupV2(driverIds: readonly number[]): readonly number[];
  setClipPresentationBatchV2(entries: readonly number[]): boolean;
  animateTimingGroupV2(...args: readonly unknown[]): number;
  animateSpringGroupV2(...args: readonly unknown[]): number;
  animateKeyframesGroupV2(...args: readonly unknown[]): number;
  cancelAnimationGroupV2(groupId: number, behavior: number): readonly number[];
  onClipGroupAnimationComplete?: typeof NativeSmoothClipModule.onClipGroupAnimationComplete;
}>;
type RequiredNativeGroupCommands = Required<
  Omit<NativeGroupHostFunctions, 'onClipGroupAnimationComplete'>
>;

const nativeGroups =
  NativeSmoothClipModule as unknown as Partial<NativeGroupHostFunctions>;
const beginGroupInteractionV2HostFunction =
  nativeGroups.beginGroupInteractionV2;
const snapshotGroupV2HostFunction = nativeGroups.snapshotGroupV2;
const setClipPresentationBatchV2HostFunction =
  nativeGroups.setClipPresentationBatchV2;
const animateTimingGroupV2HostFunction = nativeGroups.animateTimingGroupV2;
const animateSpringGroupV2HostFunction = nativeGroups.animateSpringGroupV2;
const animateKeyframesGroupV2HostFunction =
  nativeGroups.animateKeyframesGroupV2;
const cancelAnimationGroupV2HostFunction = nativeGroups.cancelAnimationGroupV2;

type RuntimeGroupRecord = Readonly<{
  controllerId: number;
  drivers: readonly SmoothClipDriver[];
}>;

type NativeGroupDriverState = {
  callbackRef: {
    current: SmoothClipGroupDriverOptions['onAnimationComplete'];
  };
  completionDeferrals: number;
  deferredCompletions: SmoothClipGroupAnimationResult[];
  effectGeneration: number;
};

const nativeGroupDriverStates = new Map<number, NativeGroupDriverState>();

function deliverNativeGroupCompletion(
  controllerId: number,
  groupId: number,
  finished: boolean
): void {
  const state = nativeGroupDriverStates.get(controllerId);
  if (!state) return;
  const result = { groupId, finished };
  if (state.completionDeferrals > 0) {
    state.deferredCompletions.push(result);
    return;
  }
  state.callbackRef.current?.(result);
}

function deferNativeGroupCompletions(controllerId: number): void {
  const state = nativeGroupDriverStates.get(controllerId);
  if (state) state.completionDeferrals += 1;
}

function releaseNativeGroupCompletions(controllerId: number): void {
  const state = nativeGroupDriverStates.get(controllerId);
  if (!state || state.completionDeferrals === 0) return;
  state.completionDeferrals -= 1;
  if (state.completionDeferrals !== 0) return;
  const deferred = state.deferredCompletions.splice(0);
  for (const result of deferred) state.callbackRef.current?.(result);
}

type GroupRuntimeGlobal = typeof globalThis & {
  __smoothClipGroupRecords?: Record<string, RuntimeGroupRecord>;
};

function runtimeGroupRecords(): Record<string, RuntimeGroupRecord> {
  'worklet';
  const runtime = globalThis as GroupRuntimeGlobal;
  runtime.__smoothClipGroupRecords ??= {};
  return runtime.__smoothClipGroupRecords;
}

function fail(message: string): never {
  'worklet';
  throw new Error(`[SmoothClipView] ${message}`);
}

function uiOnly(): never {
  'worklet';
  return fail(
    'group.ui methods must run on the UI runtime. Use group.react from React code.'
  );
}

function curveCode(presentation: CanonicalSmoothClipPresentation): number {
  'worklet';
  return presentation.clip.curve === 'continuous' ? 1 : 0;
}

function appendPresentation(
  values: number[],
  presentation: CanonicalSmoothClipPresentation
): void {
  'worklet';
  const { clip, contentTranslateX, contentTranslateY, contentScale } =
    presentation;
  values.push(
    clip.x,
    clip.y,
    clip.width,
    clip.height,
    clip.topLeftRadius,
    clip.topRightRadius,
    clip.bottomRightRadius,
    clip.bottomLeftRadius,
    curveCode(presentation),
    contentTranslateX,
    contentTranslateY,
    contentScale
  );
}

function presentationFromValues(
  values: readonly number[],
  offset: number
): CanonicalSmoothClipPresentation | null {
  'worklet';
  if (values.length < offset + PRESENTATION_STRIDE) return null;
  return canonicalizeClipPresentation({
    clip: {
      x: values[offset] as number,
      y: values[offset + 1] as number,
      width: values[offset + 2] as number,
      height: values[offset + 3] as number,
      radius: 0,
      topLeftRadius: values[offset + 4] as number,
      topRightRadius: values[offset + 5] as number,
      bottomRightRadius: values[offset + 6] as number,
      bottomLeftRadius: values[offset + 7] as number,
      curve: values[offset + 8] === 1 ? 'continuous' : 'circular',
    },
    contentTranslateX: values[offset + 9] as number,
    contentTranslateY: values[offset + 10] as number,
    contentScale: values[offset + 11] as number,
  });
}

type ValidDriver = Readonly<{
  driver: SmoothClipDriver;
  handle: SmoothClipDriverHandle;
}>;

function validateDrivers(
  drivers: readonly SmoothClipDriver[]
): readonly ValidDriver[] {
  'worklet';
  if (drivers.length === 0) return fail('A group must contain a driver.');
  const seen: Record<string, true> = {};
  const result: ValidDriver[] = [];
  for (const driver of drivers) {
    const handle = driver.__smoothClipHandle;
    if (
      driver.kind !== 'hybrid' ||
      handle === undefined ||
      !Number.isSafeInteger(handle.driverId) ||
      handle.driverId <= 0 ||
      handle.disposed.value !== 0
    ) {
      return fail('Every group participant must be a live SmoothClip driver.');
    }
    const key = String(handle.driverId);
    if (seen[key]) return fail('A group cannot contain duplicate drivers.');
    seen[key] = true;
    result.push({ driver, handle });
  }
  return result;
}

function requireNativeGroups(): RequiredNativeGroupCommands {
  'worklet';
  if (
    !GROUPS_SUPPORTED ||
    beginGroupInteractionV2HostFunction === undefined ||
    snapshotGroupV2HostFunction === undefined ||
    setClipPresentationBatchV2HostFunction === undefined ||
    animateTimingGroupV2HostFunction === undefined ||
    animateSpringGroupV2HostFunction === undefined ||
    animateKeyframesGroupV2HostFunction === undefined ||
    cancelAnimationGroupV2HostFunction === undefined
  ) {
    return fail('Native grouped presentation protocol V2 is unavailable.');
  }
  return {
    beginGroupInteractionV2: beginGroupInteractionV2HostFunction,
    snapshotGroupV2: snapshotGroupV2HostFunction,
    setClipPresentationBatchV2: setClipPresentationBatchV2HostFunction,
    animateTimingGroupV2: animateTimingGroupV2HostFunction,
    animateSpringGroupV2: animateSpringGroupV2HostFunction,
    animateKeyframesGroupV2: animateKeyframesGroupV2HostFunction,
    cancelAnimationGroupV2: cancelAnimationGroupV2HostFunction,
  };
}

type ParsedGroupSnapshots = Readonly<{
  snapshots: readonly SmoothClipGroupSnapshot[];
  unavailable: boolean;
}>;

function parseSnapshots(
  drivers: readonly SmoothClipDriver[],
  values: readonly number[]
): ParsedGroupSnapshots {
  'worklet';
  if (values.length !== drivers.length * SNAPSHOT_STRIDE) {
    return fail('Native returned an invalid group snapshot.');
  }
  const snapshots: SmoothClipGroupSnapshot[] = [];
  let unavailable = false;
  for (let index = 0; index < drivers.length; index += 1) {
    const offset = index * SNAPSHOT_STRIDE;
    const readyCode = values[offset];
    let presentation = presentationFromValues(values, offset + 1);
    if (readyCode !== 0 && readyCode !== 1) {
      return fail('Native returned an invalid group snapshot.');
    }
    if (presentation === null && readyCode === 0) {
      presentation = canonicalizeClipPresentation(
        drivers[index]?.__smoothClipHandle?.presentation.value as never
      );
      unavailable = true;
    }
    if (presentation === null) {
      return fail('Native returned an invalid group snapshot.');
    }
    snapshots.push({
      driver: drivers[index] as SmoothClipDriver,
      presentation,
      ready: readyCode === 1,
    });
  }
  return { snapshots, unavailable };
}

function applyInteractiveSnapshots(
  snapshots: readonly SmoothClipGroupSnapshot[]
): void {
  'worklet';
  // Keep individual driver listeners from re-emitting a transaction that the
  // group engine has already committed atomically.
  for (const snapshot of snapshots) {
    const handle = snapshot.driver.__smoothClipHandle;
    if (handle) handle.ownership.value = NATIVE;
  }
  for (const snapshot of snapshots) {
    const handle = snapshot.driver.__smoothClipHandle;
    if (!handle) continue;
    handle.activeAnimationId.value = 0;
    handle.presentation.value = snapshot.presentation;
    handle.ownership.value = INTERACTIVE;
  }
}

function suspensionPolicyCode(value: 'pause' | 'finish' | undefined): number {
  'worklet';
  return value === 'finish' ? 1 : 0;
}

function reduceMotionCode(value: 'system' | 'always' | 'never'): number {
  'worklet';
  if (value === 'always') return 1;
  if (value === 'never') return 2;
  return 0;
}

function animationStartTimestamp(): number {
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

function animationIsFinite(
  animation: SmoothClipGroupMotionAnimation | SmoothClipGroupKeyframeAnimation
): boolean {
  'worklet';
  if (
    animation.suspensionPolicy !== undefined &&
    animation.suspensionPolicy !== 'pause' &&
    animation.suspensionPolicy !== 'finish'
  ) {
    return false;
  }
  if (animation.type === 'timing') {
    if (
      !Array.isArray(animation.controlPoints) ||
      animation.controlPoints.length !== 4
    ) {
      return false;
    }
    const [x1, y1, x2, y2] = animation.controlPoints;
    return (
      Number.isFinite(animation.duration) &&
      animation.duration >= 0 &&
      [x1, y1, x2, y2].every(Number.isFinite) &&
      x1 >= 0 &&
      x1 <= 1 &&
      x2 >= 0 &&
      x2 <= 1
    );
  }
  if (animation.type === 'spring') {
    const initialVelocity =
      animation.initialVelocity === 'inherit' ||
      animation.initialVelocity === undefined
        ? 0
        : animation.initialVelocity;
    return (
      [
        animation.mass ?? 1,
        animation.stiffness ?? 100,
        animation.damping ?? 10,
        initialVelocity,
      ].every(Number.isFinite) &&
      (animation.mass ?? 1) > 0 &&
      (animation.stiffness ?? 100) > 0 &&
      (animation.damping ?? 10) >= 0
    );
  }
  return (
    animation.type === 'keyframes' &&
    Number.isFinite(animation.duration) &&
    animation.duration >= 0
  );
}

function springScaleIsProvablyPositive(
  starts: readonly CanonicalSmoothClipPresentation[],
  targets: readonly CanonicalSmoothClipPresentation[],
  animation: Extract<SmoothClipGroupMotionAnimation, { type: 'spring' }>
): boolean {
  'worklet';
  let changesScale = false;
  for (let index = 0; index < starts.length; index += 1) {
    if (starts[index]?.contentScale !== targets[index]?.contentScale) {
      changesScale = true;
      break;
    }
  }
  if (!changesScale) return true;

  // A zero-velocity critically/over-damped unit-step response is monotonic,
  // so interpolation stays between two already-positive endpoints. Other
  // configurations may overshoot; callers can compile those to keyframes.
  const mass = animation.mass ?? 1;
  const stiffness = animation.stiffness ?? 100;
  const damping = animation.damping ?? 10;
  return (
    animation.initialVelocity === 0 && damping * damping >= 4 * mass * stiffness
  );
}

function snapshotsForMotionStarts(
  validDrivers: readonly ValidDriver[],
  entries: readonly SmoothClipGroupMotionEntry[]
): readonly CanonicalSmoothClipPresentation[] {
  'worklet';
  const missingFrom = entries.some((entry) => entry.from === undefined);
  const sampled = missingFrom
    ? parseSnapshots(
        validDrivers.map((entry) => entry.driver),
        requireNativeGroups().snapshotGroupV2(
          validDrivers.map((entry) => entry.handle.driverId)
        )
      ).snapshots
    : [];
  const starts: CanonicalSmoothClipPresentation[] = [];
  for (let index = 0; index < entries.length; index += 1) {
    const explicit = entries[index]?.from;
    const presentation =
      explicit === undefined
        ? (sampled[index]?.presentation ?? null)
        : canonicalizeClipPresentation(explicit);
    if (presentation === null) return fail('A group start is invalid.');
    starts.push(presentation);
  }
  return starts;
}

function registerNativeGroup(
  controllerId: number,
  groupId: number,
  drivers: readonly SmoothClipDriver[],
  targets: readonly CanonicalSmoothClipPresentation[]
): void {
  'worklet';
  const records = runtimeGroupRecords();
  records[String(groupId)] = { controllerId, drivers };
  for (let index = 0; index < drivers.length; index += 1) {
    const handle = drivers[index]?.__smoothClipHandle;
    const target = targets[index];
    if (!handle || !target) continue;
    handle.ownership.value = NATIVE;
    handle.activeAnimationId.value = groupId;
    handle.presentation.value = target;
  }
}

function synchronizeGroupCompletionOnUI(
  controllerId: number,
  groupId: number,
  finished: boolean,
  driverIds: readonly number[]
): void {
  'worklet';
  const records = runtimeGroupRecords();
  const record = records[String(groupId)];
  if (
    !record ||
    record.controllerId !== controllerId ||
    record.drivers.length !== driverIds.length
  ) {
    return;
  }
  for (let index = 0; index < record.drivers.length; index += 1) {
    if (
      record.drivers[index]?.__smoothClipHandle?.driverId !== driverIds[index]
    ) {
      return;
    }
  }
  let snapshots: readonly SmoothClipGroupSnapshot[] = [];
  if (!finished) {
    try {
      snapshots = parseSnapshots(
        record.drivers,
        requireNativeGroups().snapshotGroupV2(
          record.drivers.map(
            (driver) => driver.__smoothClipHandle?.driverId ?? 0
          )
        )
      ).snapshots;
    } catch {
      snapshots = [];
    }
  }
  for (let index = 0; index < record.drivers.length; index += 1) {
    const driver = record.drivers[index];
    if (driver === undefined) continue;
    const handle = driver.__smoothClipHandle;
    if (handle === undefined || handle.activeAnimationId.value !== groupId) {
      continue;
    }
    const snapshot = snapshots[index];
    if (snapshot) handle.presentation.value = snapshot.presentation;
    handle.activeAnimationId.value = 0;
    handle.ownership.value = INTERACTIVE;
  }
  delete records[String(groupId)];
}

type PendingGroupRequest = Readonly<{
  resolve(value: unknown): void;
  reject(error: Error): void;
  teardownValue?: unknown;
  releasesCompletions?: boolean;
}>;

const pendingGroupRequests = new Map<number, PendingGroupRequest>();
const requestIdsByController = new Map<number, Set<number>>();
let nextGroupRequestId = 0;

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
  if (deferCompletions) deferNativeGroupCompletions(controllerId);
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
  if (!request) return;
  if (succeeded) request.resolve(value);
  else request.reject(new Error(message));
  if (request.releasesCompletions) {
    // One turn resolves the Promise; the second lets reactions already
    // attached to that Promise observe settlement before callbacks run.
    queueMicrotask(() => {
      queueMicrotask(() => releaseNativeGroupCompletions(controllerId));
    });
  }
}

function rejectGroupRequests(controllerId: number): void {
  const ids = requestIdsByController.get(controllerId);
  if (ids) {
    for (const requestId of ids) {
      const request = pendingGroupRequests.get(requestId);
      pendingGroupRequests.delete(requestId);
      if (!request) continue;
      if ('teardownValue' in request) request.resolve(request.teardownValue);
      else
        request.reject(
          new Error('[SmoothClipView] Group driver was destroyed.')
        );
    }
    requestIdsByController.delete(controllerId);
  }
  const state = nativeGroupDriverStates.get(controllerId);
  if (state) state.completionDeferrals = 0;
}

function detachNativeGroupDriverState(
  controllerId: number,
  state: NativeGroupDriverState
): void {
  state.completionDeferrals = 0;
  const deferred = state.deferredCompletions.splice(0);
  if (nativeGroupDriverStates.get(controllerId) === state) {
    nativeGroupDriverStates.delete(controllerId);
  }
  if (deferred.length === 0) return;
  queueMicrotask(() => {
    queueMicrotask(() => {
      for (const result of deferred) state.callbackRef.current?.(result);
    });
  });
}

function queueNativeTeardownCompletion(
  controllerId: number,
  groupId: number
): void {
  const state = nativeGroupDriverStates.get(controllerId);
  if (!state) return;
  queueMicrotask(() => {
    queueMicrotask(() => {
      state.callbackRef.current?.({ groupId, finished: false });
    });
  });
}

function finalizeNativeGroupDriverTeardown(
  controllerId: number,
  effectGeneration: number
): void {
  const state = nativeGroupDriverStates.get(controllerId);
  if (!state || state.effectGeneration !== effectGeneration) return;
  detachNativeGroupDriverState(controllerId, state);
}

function errorMessage(error: unknown): string {
  'worklet';
  return error instanceof Error
    ? error.message
    : '[SmoothClipView] Group operation failed.';
}

export function useSmoothClipGroupDriver(
  options: SmoothClipGroupDriverOptions = {}
): SmoothClipGroupDriver {
  const callbackRef = useRef(options.onAnimationComplete);
  const stateRef = useRef<NativeGroupDriverState | null>(null);
  const groupRef = useRef<SmoothClipGroupDriver | null>(null);
  const disposed = useSharedValue(0);
  callbackRef.current = options.onAnimationComplete;
  if (stateRef.current === null) {
    stateRef.current = {
      callbackRef,
      completionDeferrals: 0,
      deferredCompletions: [],
      effectGeneration: 0,
    };
  }

  if (groupRef.current === null) {
    const controllerId = allocateDriverId();
    const reduceMotion = reduceMotionCode(options.reduceMotion ?? 'system');

    const beginOnUI = (
      drivers: readonly SmoothClipDriver[]
    ): readonly SmoothClipGroupSnapshot[] => {
      'worklet';
      if (disposed.value !== 0) return fail('Group driver was destroyed.');
      const valid = validateDrivers(drivers);
      const values = requireNativeGroups().beginGroupInteractionV2(
        valid.map((entry) => entry.handle.driverId)
      );
      const parsed = parseSnapshots(drivers, values);
      // An unavailable wire presentation means native rejected the atomic
      // interaction preflight. Return readiness without changing JS ownership.
      if (!parsed.unavailable) applyInteractiveSnapshots(parsed.snapshots);
      return parsed.snapshots;
    };

    const snapshotOnUI = (
      drivers: readonly SmoothClipDriver[]
    ): readonly SmoothClipGroupSnapshot[] => {
      'worklet';
      if (disposed.value !== 0) return fail('Group driver was destroyed.');
      const valid = validateDrivers(drivers);
      return parseSnapshots(
        drivers,
        requireNativeGroups().snapshotGroupV2(
          valid.map((entry) => entry.handle.driverId)
        )
      ).snapshots;
    };

    const setBatchOnUI = (entries: readonly SmoothClipBatchEntry[]): void => {
      'worklet';
      if (disposed.value !== 0) return fail('Group driver was destroyed.');
      const valid = validateDrivers(entries.map((entry) => entry.driver));
      const canonical: CanonicalSmoothClipPresentation[] = [];
      const values: number[] = [];
      for (let index = 0; index < entries.length; index += 1) {
        const presentation = canonicalizeClipPresentation(
          entries[index]?.presentation as never
        );
        if (presentation === null)
          return fail('A batch presentation is invalid.');
        canonical.push(presentation);
        values.push(valid[index]?.handle.driverId as number);
        appendPresentation(values, presentation);
      }
      if (!requireNativeGroups().setClipPresentationBatchV2(values)) {
        return fail('Native rejected the complete presentation batch.');
      }
      for (const entry of valid) entry.handle.ownership.value = NATIVE;
      for (let index = 0; index < valid.length; index += 1) {
        const handle = valid[index]?.handle;
        const presentation = canonical[index];
        if (!handle || !presentation) continue;
        handle.activeAnimationId.value = 0;
        handle.presentation.value = presentation;
        handle.ownership.value = INTERACTIVE;
      }
    };

    const animateOnUI = (
      entries:
        | readonly SmoothClipGroupMotionEntry[]
        | readonly SmoothClipGroupKeyframeEntry[],
      animation:
        SmoothClipGroupMotionAnimation | SmoothClipGroupKeyframeAnimation
    ): number => {
      'worklet';
      if (disposed.value !== 0) return fail('Group driver was destroyed.');
      if (!animationIsFinite(animation))
        return fail('Group animation is invalid.');
      const drivers = entries.map((entry) => entry.driver);
      const valid = validateDrivers(drivers);
      const targets: CanonicalSmoothClipPresentation[] = [];
      for (const entry of entries) {
        const target = canonicalizeClipPresentation(entry.target);
        if (target === null) return fail('A group target is invalid.');
        targets.push(target);
      }
      const starts = snapshotsForMotionStarts(
        valid,
        entries as readonly SmoothClipGroupMotionEntry[]
      );
      for (let index = 0; index < starts.length; index += 1) {
        if (starts[index]?.clip.curve !== targets[index]?.clip.curve) {
          return fail('Curve-changing animations must use streamed rendering.');
        }
      }

      const native = requireNativeGroups();
      const values: number[] = [];
      let groupId = 0;
      if (animation.type === 'keyframes') {
        for (let index = 0; index < entries.length; index += 1) {
          const entry = entries[index] as SmoothClipGroupKeyframeEntry;
          const target = targets[index] as CanonicalSmoothClipPresentation;
          const start = starts[index] as CanonicalSmoothClipPresentation;
          const frames: Array<
            Readonly<{
              offset: number;
              presentation: CanonicalSmoothClipPresentation;
            }>
          > = [];
          let previousOffset = -1;
          for (const frame of entry.frames) {
            const canonical = canonicalizeClipPresentation(frame.presentation);
            const presentation =
              frames.length === 0 && entry.from === undefined
                ? start
                : canonical;
            if (
              canonical === null ||
              presentation === null ||
              !Number.isFinite(frame.offset) ||
              frame.offset <= previousOffset ||
              frame.offset < 0 ||
              frame.offset > 1 ||
              presentation.clip.curve !== target.clip.curve
            ) {
              return fail('Group keyframes are inconsistent.');
            }
            previousOffset = frame.offset;
            frames.push({ offset: frame.offset, presentation });
          }
          if (
            frames.length < 2 ||
            frames[0]?.offset !== 0 ||
            frames[frames.length - 1]?.offset !== 1 ||
            !clipPresentationEquals(
              frames[frames.length - 1]?.presentation ?? null,
              target
            ) ||
            (entry.from !== undefined &&
              !clipPresentationEquals(frames[0]?.presentation ?? null, start))
          ) {
            return fail('Group keyframes are inconsistent.');
          }
          values.push(valid[index]?.handle.driverId as number);
          values.push(entry.from === undefined ? 0 : 1);
          appendPresentation(values, start);
          appendPresentation(values, target);
          values.push(frames.length);
          for (const frame of frames) {
            values.push(frame.offset);
            appendPresentation(values, frame.presentation);
          }
        }
        groupId = native.animateKeyframesGroupV2(
          controllerId,
          values,
          animation.duration,
          reduceMotion,
          suspensionPolicyCode(animation.suspensionPolicy),
          animationStartTimestamp()
        );
      } else {
        for (let index = 0; index < entries.length; index += 1) {
          const entry = entries[index] as SmoothClipGroupMotionEntry;
          values.push(valid[index]?.handle.driverId as number);
          values.push(entry.from === undefined ? 0 : 1);
          appendPresentation(
            values,
            starts[index] as CanonicalSmoothClipPresentation
          );
          appendPresentation(
            values,
            targets[index] as CanonicalSmoothClipPresentation
          );
        }
        if (values.length !== entries.length * MOTION_ENTRY_STRIDE) {
          return fail('Internal group wire encoding failed.');
        }
        if (animation.type === 'timing') {
          const [x1, y1, x2, y2] = animation.controlPoints;
          groupId = native.animateTimingGroupV2(
            controllerId,
            values,
            animation.duration,
            x1,
            y1,
            x2,
            y2,
            reduceMotion,
            suspensionPolicyCode(animation.suspensionPolicy),
            animationStartTimestamp()
          );
        } else {
          if (!springScaleIsProvablyPositive(starts, targets, animation)) {
            return fail(
              'This scale-changing spring is not provably positive; compile it to keyframes.'
            );
          }
          const inheritVelocity =
            animation.initialVelocity === undefined ||
            animation.initialVelocity === 'inherit';
          groupId = native.animateSpringGroupV2(
            controllerId,
            values,
            animation.mass ?? 1,
            animation.stiffness ?? 100,
            animation.damping ?? 10,
            inheritVelocity ? 0 : animation.initialVelocity,
            inheritVelocity,
            reduceMotion,
            suspensionPolicyCode(animation.suspensionPolicy),
            animationStartTimestamp()
          );
        }
      }
      if (!Number.isInteger(groupId) || groupId <= 0) {
        return fail('Native rejected the complete group animation.');
      }
      registerNativeGroup(controllerId, groupId, drivers, targets);
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
      const records = runtimeGroupRecords();
      const record = records[String(groupId)];
      if (!record || record.controllerId !== controllerId) return [];
      const values = requireNativeGroups().cancelAnimationGroupV2(
        groupId,
        behavior === 'finish' ? 1 : 0
      );
      if (values.length === 0) {
        for (const driver of record.drivers) {
          const handle = driver.__smoothClipHandle;
          if (!handle || handle.activeAnimationId.value !== groupId) continue;
          handle.activeAnimationId.value = 0;
          handle.ownership.value = INTERACTIVE;
        }
        delete records[String(groupId)];
        return [];
      }
      const snapshots = parseSnapshots(record.drivers, values).snapshots;
      applyInteractiveSnapshots(snapshots);
      delete records[String(groupId)];
      return snapshots;
    };

    const group: SmoothClipGroupDriver = {
      kind: 'group',
      ui: {
        beginInteraction(drivers) {
          'worklet';
          if (isRNRuntime()) return uiOnly();
          return beginOnUI(drivers);
        },
        snapshotCurrent(drivers) {
          'worklet';
          if (isRNRuntime()) return uiOnly();
          return snapshotOnUI(drivers);
        },
        setBatch(entries) {
          'worklet';
          if (isRNRuntime()) return uiOnly();
          setBatchOnUI(entries);
        },
        animateTo(entries, animation) {
          'worklet';
          if (isRNRuntime()) return uiOnly();
          return animateOnUI(entries, animation);
        },
        cancel(groupId, behavior = 'freeze') {
          'worklet';
          if (isRNRuntime()) return uiOnly();
          return cancelOnUI(groupId, behavior);
        },
      },
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
          const { requestId, promise } = createGroupRequest<void>(
            controllerId,
            { value: undefined },
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
    controllerIds.set(group, controllerId);
    groupRef.current = group;
  }

  useEffect(() => {
    disposed.value = 0;
    const controllerId = controllerIdFor(groupRef.current);
    const state = stateRef.current;
    if (state === null) return undefined;
    state.effectGeneration += 1;
    const effectGeneration = state.effectGeneration;
    nativeGroupDriverStates.set(controllerId, state);
    let subscription: { remove(): void } | undefined;
    if (GROUPS_SUPPORTED) {
      try {
        subscription = nativeGroups.onClipGroupAnimationComplete?.((result) => {
          if (result.controllerId !== controllerId) return;
          scheduleOnUI(
            synchronizeGroupCompletionOnUI,
            result.controllerId,
            result.groupId,
            result.finished,
            result.driverIds
          );
          deliverNativeGroupCompletion(
            controllerId,
            result.groupId,
            result.finished
          );
        });
      } catch {
        // A V1 native module may expose neither the event hook nor a compatible
        // emitter facade. Unsupported setup is a no-op; UI methods still report
        // the normal capability error when invoked.
      }
    }
    return () => {
      try {
        subscription?.remove();
      } catch {
        // Older native event subscriptions are not guaranteed to support V2
        // teardown. Cleanup must remain safe across a new-JS/V1-native pair.
      }
      rejectGroupRequests(controllerId);
      scheduleOnUI(
        (ownerId: number, generation: number, gone: { value: number }) => {
          'worklet';
          gone.value = 1;
          const records = runtimeGroupRecords();
          const native = GROUPS_SUPPORTED ? requireNativeGroups() : null;
          for (const key of Object.keys(records)) {
            const record = records[key];
            if (record?.controllerId !== ownerId) continue;
            const groupId = Number(key);
            const values = native?.cancelAnimationGroupV2(groupId, 0) ?? [];
            let snapshots: readonly SmoothClipGroupSnapshot[] = [];
            if (values.length !== 0) {
              try {
                snapshots = parseSnapshots(record.drivers, values).snapshots;
              } catch {
                snapshots = [];
              }
            }
            for (let index = 0; index < record.drivers.length; index += 1) {
              const handle = record.drivers[index]?.__smoothClipHandle;
              if (!handle || handle.activeAnimationId.value !== groupId)
                continue;
              const snapshot = snapshots[index];
              if (snapshot) handle.presentation.value = snapshot.presentation;
              handle.activeAnimationId.value = 0;
              handle.ownership.value = INTERACTIVE;
            }
            delete records[key];
            if (values.length !== 0) {
              scheduleOnRN(queueNativeTeardownCompletion, ownerId, groupId);
            }
          }
          scheduleOnRN(finalizeNativeGroupDriverTeardown, ownerId, generation);
        },
        controllerId,
        effectGeneration,
        disposed
      );
    };
  }, [disposed]);

  return groupRef.current;
}

// The public object intentionally has no internal fields. Keeping the
// controller association in a WeakMap preserves that surface while allowing
// StrictMode effect replays to reuse the same native callback owner.
const controllerIds = new WeakMap<SmoothClipGroupDriver, number>();

function controllerIdFor(group: SmoothClipGroupDriver | null): number {
  if (group === null) return 0;
  const existing = controllerIds.get(group);
  if (existing !== undefined) return existing;
  const id = allocateDriverId();
  controllerIds.set(group, id);
  return id;
}

export type { SmoothClipGroupAnimationResult };
