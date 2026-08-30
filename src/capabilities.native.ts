import NativeSmoothClipModule from './smoothClipNative';
import {
  SMOOTH_CLIP_V1_CAPABILITIES,
  type SmoothClipCapabilities,
} from './capabilityTypes';

type VersionedModule = typeof NativeSmoothClipModule & {
  getPresentationProtocolVersion?: () => number;
  supportsAutonomousComplexPathAnimation?: () => boolean;
};

let cached: SmoothClipCapabilities | undefined;

export function getSmoothClipCapabilities(): SmoothClipCapabilities {
  if (cached) return cached;
  const module = NativeSmoothClipModule as VersionedModule;
  let version = 1;
  try {
    version = module.getPresentationProtocolVersion?.() === 2 ? 2 : 1;
  } catch {
    version = 1;
  }
  if (version !== 2) {
    cached = SMOOTH_CLIP_V1_CAPABILITIES;
    return cached;
  }
  let autonomousComplexPathAnimation = false;
  try {
    autonomousComplexPathAnimation =
      module.supportsAutonomousComplexPathAnimation?.() === true;
  } catch {
    autonomousComplexPathAnimation = false;
  }
  const groups =
    typeof (
      module as Partial<{
        beginGroupInteractionV2: unknown;
        snapshotGroupV2: unknown;
        setClipPresentationBatchV2: unknown;
        animateTimingGroupV2: unknown;
        animateSpringGroupV2: unknown;
        animateKeyframesGroupV2: unknown;
        cancelAnimationGroupV2: unknown;
      }>
    ).beginGroupInteractionV2 === 'function' &&
    typeof (module as Partial<{ snapshotGroupV2: unknown }>).snapshotGroupV2 ===
      'function' &&
    typeof (module as Partial<{ setClipPresentationBatchV2: unknown }>)
      .setClipPresentationBatchV2 === 'function' &&
    typeof (module as Partial<{ animateTimingGroupV2: unknown }>)
      .animateTimingGroupV2 === 'function' &&
    typeof (module as Partial<{ animateSpringGroupV2: unknown }>)
      .animateSpringGroupV2 === 'function' &&
    typeof (module as Partial<{ animateKeyframesGroupV2: unknown }>)
      .animateKeyframesGroupV2 === 'function' &&
    typeof (module as Partial<{ cancelAnimationGroupV2: unknown }>)
      .cancelAnimationGroupV2 === 'function' &&
    typeof (module as Partial<{ onClipGroupAnimationComplete: unknown }>)
      .onClipGroupAnimationComplete === 'function';
  cached = {
    presentationProtocolVersion: 2,
    groups,
    perCornerRadii: true,
    continuousCurve: true,
    contentScale: true,
    autonomousComplexPathAnimation,
  };
  return cached;
}
