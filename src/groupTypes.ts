import type {
  SmoothClipAnimation,
  SmoothClipCompletion,
  SmoothClipReactRun,
  SmoothClipRef,
  SmoothClipRunHandle,
} from './controllerTypes';
import type {
  CanonicalSmoothClipPresentation,
  SmoothClipPresentation,
} from './geometry';

export type SmoothClipGroupFrame = Readonly<{
  clip: SmoothClipRef;
  frame: SmoothClipPresentation;
}>;

export type SmoothClipGroupTarget = Readonly<{
  clip: SmoothClipRef;
  target: SmoothClipPresentation;
}>;

export type SmoothClipGroupSnapshot = Readonly<{
  clip: SmoothClipRef;
  frame: CanonicalSmoothClipPresentation;
  ready: boolean;
}>;

export type SmoothClipGroupOptions = Readonly<{
  /** Stable React-runtime callback for UI- and React-runtime transactions. */
  onAnimationComplete?: (result: SmoothClipCompletion) => void;
}>;

export type SmoothClipGroup = Readonly<{
  ui: Readonly<{
    setFrames(entries: readonly SmoothClipGroupFrame[]): void;
    beginInteraction(
      clips: readonly SmoothClipRef[]
    ): readonly SmoothClipGroupSnapshot[];
    animateTo(
      entries: readonly SmoothClipGroupTarget[],
      animation: SmoothClipAnimation,
      completionTag?: number
    ): SmoothClipRunHandle | null;
    cancel(run: SmoothClipRunHandle): readonly SmoothClipGroupSnapshot[];
  }>;
  react: Readonly<{
    animateTo(
      entries: readonly SmoothClipGroupTarget[],
      animation: SmoothClipAnimation
    ): SmoothClipReactRun;
  }>;
}>;
