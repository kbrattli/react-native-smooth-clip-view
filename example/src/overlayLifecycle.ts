import type { ClipAnimationResult } from 'react-native-smooth-clip-view';
import {
  OVERLAY_PHASE_CLOSING,
  OVERLAY_PHASE_OPENING,
  type OverlayPhase,
} from './overlayPhases';

export type OverlayCompletionAction =
  'ignore' | 'complete-opening' | 'complete-closing' | 'recover-closing';

export function resolveOverlayCompletionAction(
  phase: OverlayPhase,
  openingAnimationId: number,
  closingAnimationId: number,
  result: ClipAnimationResult
): OverlayCompletionAction {
  'worklet';
  if (phase === OVERLAY_PHASE_OPENING) {
    return openingAnimationId !== 0 &&
      result.animationId === openingAnimationId &&
      result.finished
      ? 'complete-opening'
      : 'ignore';
  }
  if (
    phase !== OVERLAY_PHASE_CLOSING ||
    closingAnimationId === 0 ||
    result.animationId !== closingAnimationId
  ) {
    return 'ignore';
  }
  return result.finished ? 'complete-closing' : 'recover-closing';
}
