import type {
  ClipReduceMotion,
  SmoothClipDriver,
  SpringClipAnimation,
  TimingClipAnimation,
} from './driverTypes';
import type {
  CanonicalSmoothClipPresentation,
  SmoothClipPresentation,
} from './geometry';

export type SmoothClipGroupAnimationResult = Readonly<{
  groupId: number;
  finished: boolean;
}>;

export type SmoothClipGroupSnapshot = Readonly<{
  driver: SmoothClipDriver;
  presentation: CanonicalSmoothClipPresentation;
  ready: boolean;
}>;

export type SmoothClipBatchEntry = Readonly<{
  driver: SmoothClipDriver;
  presentation: SmoothClipPresentation;
}>;

export type SmoothClipGroupMotionEntry = Readonly<{
  driver: SmoothClipDriver;
  target: SmoothClipPresentation;
  from?: SmoothClipPresentation;
}>;

export type SmoothClipGroupKeyframeEntry = SmoothClipGroupMotionEntry &
  Readonly<{
    frames: readonly Readonly<{
      offset: number;
      presentation: SmoothClipPresentation;
    }>[];
  }>;

export type SmoothClipGroupSuspensionPolicy = 'pause' | 'finish';
export type SmoothClipGroupCancelBehavior = 'freeze' | 'finish';

type SmoothClipGroupAnimationBase = Readonly<{
  suspensionPolicy?: SmoothClipGroupSuspensionPolicy;
}>;

export type SmoothClipGroupTimingAnimation = Omit<TimingClipAnimation, 'from'> &
  SmoothClipGroupAnimationBase;

export type SmoothClipGroupSpringAnimation = Omit<SpringClipAnimation, 'from'> &
  SmoothClipGroupAnimationBase;

export type SmoothClipGroupKeyframeAnimation = Readonly<{
  type: 'keyframes';
  duration: number;
  suspensionPolicy?: SmoothClipGroupSuspensionPolicy;
}>;

export type SmoothClipGroupMotionAnimation =
  SmoothClipGroupTimingAnimation | SmoothClipGroupSpringAnimation;

export type SmoothClipGroupDriverOptions = Readonly<{
  reduceMotion?: ClipReduceMotion;
  onAnimationComplete?: (result: SmoothClipGroupAnimationResult) => void;
}>;

export interface SmoothClipGroupUIControls {
  beginInteraction(
    drivers: readonly SmoothClipDriver[]
  ): readonly SmoothClipGroupSnapshot[];
  snapshotCurrent(
    drivers: readonly SmoothClipDriver[]
  ): readonly SmoothClipGroupSnapshot[];
  setBatch(entries: readonly SmoothClipBatchEntry[]): void;
  animateTo(
    entries: readonly SmoothClipGroupMotionEntry[],
    animation: SmoothClipGroupMotionAnimation
  ): number;
  animateTo(
    entries: readonly SmoothClipGroupKeyframeEntry[],
    animation: SmoothClipGroupKeyframeAnimation
  ): number;
  cancel(
    groupId: number,
    behavior?: SmoothClipGroupCancelBehavior
  ): readonly SmoothClipGroupSnapshot[];
}

export interface SmoothClipGroupReactControls {
  beginInteraction(
    drivers: readonly SmoothClipDriver[]
  ): Promise<readonly SmoothClipGroupSnapshot[]>;
  snapshotCurrent(
    drivers: readonly SmoothClipDriver[]
  ): Promise<readonly SmoothClipGroupSnapshot[]>;
  setBatch(entries: readonly SmoothClipBatchEntry[]): Promise<void>;
  animateTo(
    entries: readonly SmoothClipGroupMotionEntry[],
    animation: SmoothClipGroupMotionAnimation
  ): Promise<number>;
  animateTo(
    entries: readonly SmoothClipGroupKeyframeEntry[],
    animation: SmoothClipGroupKeyframeAnimation
  ): Promise<number>;
  cancel(
    groupId: number,
    behavior?: SmoothClipGroupCancelBehavior
  ): Promise<readonly SmoothClipGroupSnapshot[]>;
}

export type SmoothClipGroupDriver = Readonly<{
  kind: 'group';
  ui: SmoothClipGroupUIControls;
  react: SmoothClipGroupReactControls;
}>;
