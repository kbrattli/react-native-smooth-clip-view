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
  setClipPresentation(
    driverId: CodegenTypes.Double,
    x: CodegenTypes.Double,
    y: CodegenTypes.Double,
    width: CodegenTypes.Double,
    height: CodegenTypes.Double,
    radius: CodegenTypes.Double,
    contentTranslateX: CodegenTypes.Double,
    contentTranslateY: CodegenTypes.Double,
    takeOwnership: boolean,
    overridePendingAnimation: boolean
  ): void;
  beginInteraction(
    driverId: CodegenTypes.Double
  ): ReadonlyArray<CodegenTypes.Double>;
  animateTiming(
    driverId: CodegenTypes.Double,
    hasInteractiveStart: boolean,
    startX: CodegenTypes.Double,
    startY: CodegenTypes.Double,
    startWidth: CodegenTypes.Double,
    startHeight: CodegenTypes.Double,
    startRadius: CodegenTypes.Double,
    startContentTranslateX: CodegenTypes.Double,
    startContentTranslateY: CodegenTypes.Double,
    x: CodegenTypes.Double,
    y: CodegenTypes.Double,
    width: CodegenTypes.Double,
    height: CodegenTypes.Double,
    radius: CodegenTypes.Double,
    contentTranslateX: CodegenTypes.Double,
    contentTranslateY: CodegenTypes.Double,
    durationMs: CodegenTypes.Double,
    controlPoint1X: CodegenTypes.Double,
    controlPoint1Y: CodegenTypes.Double,
    controlPoint2X: CodegenTypes.Double,
    controlPoint2Y: CodegenTypes.Double,
    reduceMotion: CodegenTypes.Int32
  ): CodegenTypes.Int32;
  animateSpring(
    driverId: CodegenTypes.Double,
    hasInteractiveStart: boolean,
    startX: CodegenTypes.Double,
    startY: CodegenTypes.Double,
    startWidth: CodegenTypes.Double,
    startHeight: CodegenTypes.Double,
    startRadius: CodegenTypes.Double,
    startContentTranslateX: CodegenTypes.Double,
    startContentTranslateY: CodegenTypes.Double,
    x: CodegenTypes.Double,
    y: CodegenTypes.Double,
    width: CodegenTypes.Double,
    height: CodegenTypes.Double,
    radius: CodegenTypes.Double,
    contentTranslateX: CodegenTypes.Double,
    contentTranslateY: CodegenTypes.Double,
    mass: CodegenTypes.Double,
    stiffness: CodegenTypes.Double,
    damping: CodegenTypes.Double,
    initialVelocity: CodegenTypes.Double,
    inheritVelocity: boolean,
    reduceMotion: CodegenTypes.Int32
  ): CodegenTypes.Int32;
  animateKeyframes(
    driverId: CodegenTypes.Double,
    hasInteractiveStart: boolean,
    startX: CodegenTypes.Double,
    startY: CodegenTypes.Double,
    startWidth: CodegenTypes.Double,
    startHeight: CodegenTypes.Double,
    startRadius: CodegenTypes.Double,
    startContentTranslateX: CodegenTypes.Double,
    startContentTranslateY: CodegenTypes.Double,
    x: CodegenTypes.Double,
    y: CodegenTypes.Double,
    width: CodegenTypes.Double,
    height: CodegenTypes.Double,
    radius: CodegenTypes.Double,
    contentTranslateX: CodegenTypes.Double,
    contentTranslateY: CodegenTypes.Double,
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
