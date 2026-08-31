import type { CodegenTypes, TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

export interface Spec extends TurboModule {
  readonly onClipAnimationComplete: CodegenTypes.EventEmitter<
    Readonly<{
      driverId: CodegenTypes.Double;
      animationId: CodegenTypes.Int32;
      finished: boolean;
    }>
  >;
  readonly onClipGroupAnimationComplete: CodegenTypes.EventEmitter<
    Readonly<{
      controllerId: CodegenTypes.Double;
      groupId: CodegenTypes.Int32;
      finished: boolean;
      driverIds: ReadonlyArray<CodegenTypes.Double>;
    }>
  >;
  supportsAutonomousComplexPathAnimation(): boolean;
  beginGroupInteraction(
    driverIds: ReadonlyArray<CodegenTypes.Double>
  ): ReadonlyArray<CodegenTypes.Double>;
  snapshotGroup(
    driverIds: ReadonlyArray<CodegenTypes.Double>
  ): ReadonlyArray<CodegenTypes.Double>;
  setClipPresentationBatch(
    entries: ReadonlyArray<CodegenTypes.Double>
  ): boolean;
  animateTimingGroup(
    controllerId: CodegenTypes.Double,
    entries: ReadonlyArray<CodegenTypes.Double>,
    durationMs: CodegenTypes.Double,
    controlPoint1X: CodegenTypes.Double,
    controlPoint1Y: CodegenTypes.Double,
    controlPoint2X: CodegenTypes.Double,
    controlPoint2Y: CodegenTypes.Double,
    reduceMotion: CodegenTypes.Int32,
    suspensionPolicy: CodegenTypes.Int32
  ): CodegenTypes.Int32;
  animateSpringGroup(
    controllerId: CodegenTypes.Double,
    entries: ReadonlyArray<CodegenTypes.Double>,
    mass: CodegenTypes.Double,
    stiffness: CodegenTypes.Double,
    damping: CodegenTypes.Double,
    initialVelocity: CodegenTypes.Double,
    inheritVelocity: boolean,
    reduceMotion: CodegenTypes.Int32,
    suspensionPolicy: CodegenTypes.Int32
  ): CodegenTypes.Int32;
  animateKeyframesGroup(
    controllerId: CodegenTypes.Double,
    entries: ReadonlyArray<CodegenTypes.Double>,
    durationMs: CodegenTypes.Double,
    reduceMotion: CodegenTypes.Int32,
    suspensionPolicy: CodegenTypes.Int32
  ): CodegenTypes.Int32;
  cancelAnimationGroup(
    groupId: CodegenTypes.Int32,
    behavior: CodegenTypes.Int32
  ): ReadonlyArray<CodegenTypes.Double>;
  setClipPresentation(
    driverId: CodegenTypes.Double,
    presentation: ReadonlyArray<CodegenTypes.Double>,
    takeOwnership: boolean,
    overridePendingAnimation: boolean
  ): void;
  setClipPresentationScalars(
    driverId: CodegenTypes.Double,
    x: CodegenTypes.Double,
    y: CodegenTypes.Double,
    width: CodegenTypes.Double,
    height: CodegenTypes.Double,
    topLeftRadius: CodegenTypes.Double,
    topRightRadius: CodegenTypes.Double,
    bottomRightRadius: CodegenTypes.Double,
    bottomLeftRadius: CodegenTypes.Double,
    curveCode: CodegenTypes.Int32,
    contentTranslateX: CodegenTypes.Double,
    contentTranslateY: CodegenTypes.Double,
    contentScale: CodegenTypes.Double,
    overridePendingAnimation: boolean,
    recordVelocity: boolean
  ): void;
  beginInteraction(
    driverId: CodegenTypes.Double
  ): ReadonlyArray<CodegenTypes.Double>;
  snapshotCurrent(
    driverId: CodegenTypes.Double
  ): ReadonlyArray<CodegenTypes.Double>;
  animateTiming(
    driverId: CodegenTypes.Double,
    start: ReadonlyArray<CodegenTypes.Double>,
    target: ReadonlyArray<CodegenTypes.Double>,
    durationMs: CodegenTypes.Double,
    controlPoint1X: CodegenTypes.Double,
    controlPoint1Y: CodegenTypes.Double,
    controlPoint2X: CodegenTypes.Double,
    controlPoint2Y: CodegenTypes.Double,
    reduceMotion: CodegenTypes.Int32
  ): CodegenTypes.Int32;
  animateSpring(
    driverId: CodegenTypes.Double,
    start: ReadonlyArray<CodegenTypes.Double>,
    target: ReadonlyArray<CodegenTypes.Double>,
    mass: CodegenTypes.Double,
    stiffness: CodegenTypes.Double,
    damping: CodegenTypes.Double,
    initialVelocity: CodegenTypes.Double,
    inheritVelocity: boolean,
    reduceMotion: CodegenTypes.Int32
  ): CodegenTypes.Int32;
  animateKeyframes(
    driverId: CodegenTypes.Double,
    start: ReadonlyArray<CodegenTypes.Double>,
    target: ReadonlyArray<CodegenTypes.Double>,
    durationMs: CodegenTypes.Double,
    frames: ReadonlyArray<CodegenTypes.Double>,
    reduceMotion: CodegenTypes.Int32
  ): CodegenTypes.Int32;
  rejectAnimation(driverId: CodegenTypes.Double): CodegenTypes.Int32;
  cancelAnimation(
    driverId: CodegenTypes.Double,
    animationId: CodegenTypes.Int32,
    behavior: CodegenTypes.Int32
  ): ReadonlyArray<CodegenTypes.Double>;
  destroyDriver(driverId: CodegenTypes.Double): void;
}

export default TurboModuleRegistry.getEnforcing<Spec>('NativeSmoothClipModule');
