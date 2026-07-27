import type { SharedValue } from 'react-native-reanimated';
import type { SmoothClipPresentation } from './geometry';

export type ClipReduceMotion = 'system' | 'always' | 'never';

export type TimingClipAnimation = Readonly<{
  type: 'timing';
  duration: number;
  controlPoints: readonly [number, number, number, number];
}>;

export type SpringClipAnimation = Readonly<{
  type: 'spring';
  mass?: number;
  stiffness?: number;
  damping?: number;
  initialVelocity?: number | 'inherit';
}>;

export type KeyframedClipAnimation = Readonly<{
  type: 'keyframes';
  duration: number;
  frames: readonly Readonly<{
    offset: number;
    presentation: SmoothClipPresentation;
  }>[];
}>;

export type SmoothClipAnimation =
  TimingClipAnimation | SpringClipAnimation | KeyframedClipAnimation;

export type ClipAnimationResult = Readonly<{
  animationId: number;
  finished: boolean;
}>;

export type SmoothClipDriverOptions = Readonly<{
  reduceMotion?: ClipReduceMotion;
  onAnimationComplete?: (result: ClipAnimationResult) => void;
}>;

export type SmoothClipUIControls = Readonly<{
  beginInteraction(): SmoothClipPresentation;
  set(presentation: SmoothClipPresentation): void;
  /**
   * Per-frame hot path: writes geometry straight to native without touching
   * `driver.presentation`. Skips SharedValue bookkeeping (dirty marking, RN
   * mirror sync, listener dispatch) for high-frequency streams such as
   * gestures. `driver.presentation.value` is stale after hot writes by design;
   * `beginInteraction()` remains the source of truth for visible geometry.
   * Do not interleave with `presentation.value` writes on the same driver —
   * the listener's duplicate suppression may skip a later equal value.
   */
  setScalars(
    x: number,
    y: number,
    width: number,
    height: number,
    radius: number,
    contentTranslateX: number,
    contentTranslateY: number
  ): void;
  animateTo(
    presentation: SmoothClipPresentation,
    animation: SmoothClipAnimation
  ): number;
  cancel(
    animationId?: number,
    behavior?: 'current' | 'target'
  ): SmoothClipPresentation;
}>;

export type SmoothClipReactControls = Readonly<{
  beginInteraction(): Promise<SmoothClipPresentation>;
  set(presentation: SmoothClipPresentation): Promise<void>;
  animateTo(
    presentation: SmoothClipPresentation,
    animation: SmoothClipAnimation
  ): Promise<number>;
  cancel(
    animationId?: number,
    behavior?: 'current' | 'target'
  ): Promise<SmoothClipPresentation>;
}>;

export type SmoothClipDriver = Readonly<{
  kind: 'hybrid';
  presentation: SharedValue<SmoothClipPresentation>;
  ui: SmoothClipUIControls;
  react: SmoothClipReactControls;
}>;
