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
    /**
     * Initial progress velocity in inverse seconds; defaults to 0. Each
     * changing channel, including rotation and opacity, starts at
     * velocity * (target - start).
     *
     * `'inherit'` takes the velocity the host is moving with when this run
     * replaces it: the replaced run's analytic velocity (timing or spring),
     * or the velocity of the frames an interaction streamed through
     * `setFrame`, projected onto this run's displacement. A host at rest
     * inherits 0. Use it to retarget a flight mid-air or to release a drag.
     */
    velocity?: number | 'inherit';
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
  /**
   * True once the mounted host is on screen: it has a non-zero layout and is
   * attached to a visible window, and on iOS its layer has been committed, so
   * a run started now cannot join the mount's own commit partway through its
   * curve. (On Android the mount and the UI frame share one draw.) A pure read
   * of native views, so it never holds before the host's mount, unlike
   * `onLayout` or `measure`, which report the shadow tree. A UI frame that sees
   * it true runs after that whole mount, so everything mounted with the host
   * exists too.
   */
  isReady(): boolean;
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
