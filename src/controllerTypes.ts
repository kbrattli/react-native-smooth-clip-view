import type {
  CanonicalSmoothClipPresentation,
  ClipGeometry,
  SmoothClipPresentation,
} from './geometry';

export type ClipReduceMotion = 'system' | 'always' | 'never';

type SmoothClipAnimationBase = Readonly<{
  /** Resolved per transaction; it is never retained by the controller. */
  reduceMotion?: ClipReduceMotion;
}>;

export type TimingClipAnimation = SmoothClipAnimationBase &
  Readonly<{
    type: 'timing';
    duration: number;
    controlPoints: readonly [number, number, number, number];
  }>;

export type SpringClipAnimation = SmoothClipAnimationBase &
  Readonly<{
    type: 'spring';
    mass?: number;
    stiffness?: number;
    damping?: number;
    /** Normalized progress velocity in inverse seconds. */
    velocity?: number;
    /** Relative mechanical energy used to determine settlement. */
    energyThreshold?: number;
  }>;

export type SmoothClipAnimation = TimingClipAnimation | SpringClipAnimation;

declare const smoothClipRefBrand: unique symbol;
/** Opaque, worklet-safe identity for one mounted clip host. */
export type SmoothClipRef = Readonly<{
  readonly [smoothClipRefBrand]: true;
}>;

declare const smoothClipRunBrand: unique symbol;
/** Opaque identity for a native transaction started on the UI runtime. */
export type SmoothClipRunHandle = Readonly<{
  readonly [smoothClipRunBrand]: true;
}>;

export type SmoothClipCompletion = Readonly<{
  finished: boolean;
  /** Present only when supplied by the UI-runtime caller. */
  completionTag?: number;
}>;

export type SmoothClipReactRun = Readonly<{
  finished: Promise<boolean>;
  cancel(): void;
}>;

export type SmoothClipControllerOptions = Readonly<{
  /** Stable React-runtime callback for UI- and React-runtime transactions. */
  onAnimationComplete?: (result: SmoothClipCompletion) => void;
}>;

export type SmoothClipControllerUI = Readonly<{
  beginInteraction(): CanonicalSmoothClipPresentation;
  setFrame(frame: SmoothClipPresentation): void;
  animateTo(
    target: SmoothClipPresentation,
    animation: SmoothClipAnimation,
    completionTag?: number
  ): SmoothClipRunHandle | null;
  cancel(run: SmoothClipRunHandle): CanonicalSmoothClipPresentation;
}>;

export type SmoothClipControllerReact = Readonly<{
  animateTo(
    target: SmoothClipPresentation,
    animation: SmoothClipAnimation
  ): SmoothClipReactRun;
}>;

export type SmoothClipController = Readonly<{
  ref: SmoothClipRef;
  ui: SmoothClipControllerUI;
  react: SmoothClipControllerReact;
}>;

export type SmoothClipInitialFrame = ClipGeometry | SmoothClipPresentation;
