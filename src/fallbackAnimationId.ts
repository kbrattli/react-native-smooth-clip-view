type FallbackAnimationRuntimeGlobal = typeof globalThis & {
  __smoothClipFallbackNextAnimationId?: number;
};

/**
 * Allocates from one UI-runtime namespace shared by fallback single-driver and
 * grouped animations. Ownership records can therefore never confuse an equal
 * numeric id from the other fallback path for continued ownership.
 */
export function allocateFallbackAnimationId(): number {
  'worklet';
  const runtime = globalThis as FallbackAnimationRuntimeGlobal;
  const previous = runtime.__smoothClipFallbackNextAnimationId ?? 0;
  const next = (previous % 0x7ffffffe) + 1;
  runtime.__smoothClipFallbackNextAnimationId = next;
  return next;
}
