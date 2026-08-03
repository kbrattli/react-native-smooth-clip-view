import {
  deferDriverCompletions,
  releaseDriverCompletions,
} from './driverState';

type PendingRequest = {
  resolve(value: unknown): void;
  reject(error: Error): void;
  // Set for calls whose documented usage is fire-and-forget (`void
  // driver.react.animateTo(...)`): teardown resolves them with this benign
  // sentinel instead of rejecting, so a discarded promise cannot surface as
  // an unhandled rejection during ordinary unmount.
  teardownResolution?: { value: unknown };
};

const requests = new Map<number, PendingRequest>();
const requestsByDriver = new Map<number, Set<number>>();
let nextRequestId = 0;

export function createReactRequest<T>(
  driverId: number,
  deferCompletions = false,
  teardownResolution?: { value: unknown }
): { requestId: number; promise: Promise<T> } {
  nextRequestId = (nextRequestId % 0x7ffffffe) + 1;
  const requestId = nextRequestId;
  let resolveRequest!: (value: T) => void;
  let rejectRequest!: (error: Error) => void;
  const promise = new Promise<T>((resolve, reject) => {
    resolveRequest = resolve;
    rejectRequest = reject;
  });
  requests.set(requestId, {
    resolve: resolveRequest as (value: unknown) => void,
    reject: rejectRequest,
    teardownResolution,
  });
  const driverRequests = requestsByDriver.get(driverId) ?? new Set<number>();
  driverRequests.add(requestId);
  requestsByDriver.set(driverId, driverRequests);
  if (deferCompletions) deferDriverCompletions(driverId);
  return { requestId, promise };
}

export function resolveReactRequest(
  driverId: number,
  requestId: number,
  value: unknown,
  releaseCompletions = false
): void {
  const request = requests.get(requestId);
  requests.delete(requestId);
  const driverRequests = requestsByDriver.get(driverId);
  driverRequests?.delete(requestId);
  if (driverRequests?.size === 0) requestsByDriver.delete(driverId);
  request?.resolve(value);
  if (releaseCompletions) {
    queueMicrotask(() => releaseDriverCompletions(driverId));
  }
}

export function rejectDriverRequests(driverId: number): void {
  const driverRequests = requestsByDriver.get(driverId);
  if (!driverRequests) return;
  for (const requestId of driverRequests) {
    const request = requests.get(requestId);
    requests.delete(requestId);
    if (!request) continue;
    if (request.teardownResolution) {
      request.resolve(request.teardownResolution.value);
    } else {
      request.reject(new Error('[SmoothClipView] Driver was destroyed.'));
    }
  }
  requestsByDriver.delete(driverId);
}
