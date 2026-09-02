import type { SmoothClipController, SmoothClipRef } from './controllerTypes';
import type { CanonicalSmoothClipPresentation } from './geometry';

export type InternalSmoothClipController = Readonly<{
  ref: SmoothClipRef;
  initialFrame: CanonicalSmoothClipPresentation;
}>;

export type InternalSmoothClipRef = SmoothClipRef & Readonly<{ id: number }>;

const controllers = new WeakMap<
  SmoothClipController,
  InternalSmoothClipController
>();

export function setControllerRef(
  controller: SmoothClipController,
  value: InternalSmoothClipController
): void {
  controllers.set(controller, value);
}

export function getControllerRef(
  controller: SmoothClipController
): InternalSmoothClipController {
  const value = controllers.get(controller);
  if (!value) {
    throw new Error(
      '[SmoothClipView] Controllers must be created by useSmoothClipController.'
    );
  }
  return value;
}

export function unwrapSmoothClipRef(
  ref: SmoothClipRef | undefined
): InternalSmoothClipRef | undefined {
  'worklet';
  const internal = ref as InternalSmoothClipRef | undefined;
  if (
    internal === undefined ||
    !Number.isSafeInteger(internal.id) ||
    internal.id <= 0
  ) {
    return undefined;
  }
  return internal;
}

export function createSmoothClipRef(id: number): SmoothClipRef {
  return { id } as InternalSmoothClipRef;
}
