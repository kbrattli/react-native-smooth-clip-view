import { describe, expect, it } from '@jest/globals';
import {
  OVERLAY_PHASE_CLOSING,
  OVERLAY_PHASE_OPEN,
  OVERLAY_PHASE_OPENING,
} from '../overlayPhases';
import { resolveOverlayCompletionAction } from '../overlayLifecycle';

describe('zoom overlay native completion routing', () => {
  it('completes opening only after a finished native animation', () => {
    expect(
      resolveOverlayCompletionAction(OVERLAY_PHASE_OPENING, 4, 0, {
        animationId: 4,
        finished: true,
      })
    ).toBe('complete-opening');
    expect(
      resolveOverlayCompletionAction(OVERLAY_PHASE_OPENING, 4, 0, {
        animationId: 4,
        finished: false,
      })
    ).toBe('ignore');
  });

  it('ignores stale opening completions', () => {
    expect(
      resolveOverlayCompletionAction(OVERLAY_PHASE_OPENING, 5, 0, {
        animationId: 4,
        finished: true,
      })
    ).toBe('ignore');
  });

  it('completes closing only for the matching successful animation', () => {
    expect(
      resolveOverlayCompletionAction(OVERLAY_PHASE_CLOSING, 0, 8, {
        animationId: 8,
        finished: true,
      })
    ).toBe('complete-closing');
    expect(
      resolveOverlayCompletionAction(OVERLAY_PHASE_CLOSING, 0, 8, {
        animationId: 7,
        finished: true,
      })
    ).toBe('ignore');
  });

  it('recovers rather than closing after a rejected native animation', () => {
    expect(
      resolveOverlayCompletionAction(OVERLAY_PHASE_CLOSING, 0, 8, {
        animationId: 8,
        finished: false,
      })
    ).toBe('recover-closing');
    expect(
      resolveOverlayCompletionAction(OVERLAY_PHASE_OPEN, 0, 8, {
        animationId: 8,
        finished: false,
      })
    ).toBe('ignore');
  });
});
