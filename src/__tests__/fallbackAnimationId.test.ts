import { afterEach, describe, expect, it } from '@jest/globals';
import { allocateFallbackAnimationId } from '../fallbackAnimationId';

type Runtime = typeof globalThis & {
  __smoothClipFallbackNextAnimationId?: number;
};

afterEach(() => {
  delete (globalThis as Runtime).__smoothClipFallbackNextAnimationId;
});

describe('fallback animation ids', () => {
  it('allocates one process-global namespace for every fallback owner', () => {
    expect(allocateFallbackAnimationId()).toBe(1);
    expect(allocateFallbackAnimationId()).toBe(2);
    expect(allocateFallbackAnimationId()).toBe(3);
  });

  it('wraps without returning the zero sentinel', () => {
    (globalThis as Runtime).__smoothClipFallbackNextAnimationId = 0x7ffffffe;
    expect(allocateFallbackAnimationId()).toBe(1);
  });
});
