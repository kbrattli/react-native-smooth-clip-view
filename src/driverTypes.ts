import type { SharedValue } from 'react-native-reanimated';
import type { SmoothClipPresentation } from './geometry';

export type ClipReduceMotion = 'system' | 'always' | 'never';

/** Options shared by every animation kind. */
type ClipAnimationBase = Readonly<{
  /**
   * Explicit start: fuses a `setScalars(from…)` take-ownership hot write
   * immediately before the animation, so native starts from exactly this
   * presentation instead of its last delivered value. Use at a gesture
   * release when the freshest sample (e.g. the UP event's position) never
   * reached native — a gated per-frame reaction may not have flushed it.
   * Also re-grabs from a running animation (which an implicit interactive
   * start would silently skip). Non-finite `from` rejects the whole call.
   * `driver.presentation.value` is not written from `from` (it stays stale
   * until success sets it to the target). Against a held pending-animation
   * latch the seed is dropped by design — latch intent wins.
   *
   * Keyframes interpolate absolutely, so pass `frames[0].presentation` —
   * the seed renders it before the first animation frame, making the
   * handoff continuous.
   *
   * iOS note: keyframes start exactly at `from` (frame 0 travels in-band);
   * timing/spring sample their Core Animation from-value off the
   * presentation layer — the last committed frame, at most one frame behind
   * `from` — identical to the two-call pattern this option desugars to.
   */
  from?: SmoothClipPresentation;
}>;

export type TimingClipAnimation = ClipAnimationBase &
  Readonly<{
    type: 'timing';
    duration: number;
    controlPoints: readonly [number, number, number, number];
  }>;

export type SpringClipAnimation = ClipAnimationBase &
  Readonly<{
    type: 'spring';
    mass?: number;
    stiffness?: number;
    damping?: number;
    initialVelocity?: number | 'inherit';
  }>;

export type KeyframedClipAnimation = ClipAnimationBase &
  Readonly<{
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
   * To hand off into an animation from a fresher value than the last hot
   * write, pass the geometry as `animation.from` to `animateTo` — it fuses
   * this call and the handoff into one.
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
