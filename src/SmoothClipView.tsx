import type React from 'react';
import {
  forwardRef,
  type ReactNode,
  useEffect,
  useImperativeHandle,
} from 'react';
import { type ViewProps } from 'react-native';
import Animated, {
  dispatchCommand,
  useAnimatedReaction,
  useAnimatedRef,
} from 'react-native-reanimated';
import type { SmoothClipDriver } from './driverTypes';
import { getDriverState, registerDriverView } from './driverState';
import { getSmoothClipCapabilities } from './capabilities';
import {
  canonicalizeClipPresentation,
  clipPresentationEquals,
  isFiniteClipPresentation,
} from './geometry';
import { assertInitialPresentationProtocol } from './presentationProtocol';
import NativeSmoothClipView, {
  type NativeProps,
} from './SmoothClipViewNativeComponent';

const AnimatedNativeSmoothClipView =
  Animated.createAnimatedComponent(NativeSmoothClipView);

export type SmoothClipViewProps = ViewProps & {
  driver: SmoothClipDriver;
  children?: ReactNode;
};

/** Android fallback. iOS resolves SmoothClipView.ios.tsx instead. */
export const SmoothClipView = forwardRef<
  React.ComponentRef<typeof NativeSmoothClipView>,
  SmoothClipViewProps
>(function SmoothClipViewComponent(
  { driver, children, ...viewProps },
  forwardedRef
) {
  const { driverId, initialPresentation, source } = getDriverState(driver);
  const canonicalInitial = canonicalizeClipPresentation(initialPresentation)!;
  const { clip } = canonicalInitial;
  const protocolVersion =
    getSmoothClipCapabilities().presentationProtocolVersion;
  useEffect(() => registerDriverView(driver), [driver]);
  const nativeRef =
    useAnimatedRef<React.ComponentRef<typeof NativeSmoothClipView>>();
  useImperativeHandle(forwardedRef, () => nativeRef.current!, [nativeRef]);

  useAnimatedReaction(
    () => source.value,
    (presentation, previousPresentation) => {
      if (
        !isFiniteClipPresentation(presentation) ||
        clipPresentationEquals(previousPresentation, presentation)
      ) {
        return;
      }

      const canonical = canonicalizeClipPresentation(presentation);
      if (canonical === null) return;
      if (protocolVersion === 2) {
        dispatchCommand(nativeRef, 'setClipPresentationV2', [
          canonical.clip.x,
          canonical.clip.y,
          canonical.clip.width,
          canonical.clip.height,
          canonical.clip.topLeftRadius,
          canonical.clip.topRightRadius,
          canonical.clip.bottomRightRadius,
          canonical.clip.bottomLeftRadius,
          canonical.clip.curve === 'continuous' ? 1 : 0,
          canonical.contentTranslateX,
          canonical.contentTranslateY,
          canonical.contentScale,
        ]);
      } else {
        dispatchCommand(nativeRef, 'setClipPresentation', [
          canonical.clip.x,
          canonical.clip.y,
          canonical.clip.width,
          canonical.clip.height,
          canonical.clip.radius,
          canonical.contentTranslateX,
          canonical.contentTranslateY,
        ]);
      }
    },
    [nativeRef, protocolVersion, source]
  );

  assertInitialPresentationProtocol(canonicalInitial, protocolVersion);

  const nativeProps: NativeProps = {
    ...viewProps,
    driverId,
    initialClipX: clip.x,
    initialClipY: clip.y,
    initialClipWidth: clip.width,
    initialClipHeight: clip.height,
    initialClipRadius: clip.radius,
    presentationVersion: protocolVersion,
    initialClipTopLeftRadius: clip.topLeftRadius,
    initialClipTopRightRadius: clip.topRightRadius,
    initialClipBottomRightRadius: clip.bottomRightRadius,
    initialClipBottomLeftRadius: clip.bottomLeftRadius,
    initialClipCurve: clip.curve === 'continuous' ? 1 : 0,
    initialContentTranslateX: canonicalInitial.contentTranslateX,
    initialContentTranslateY: canonicalInitial.contentTranslateY,
    initialContentScale: canonicalInitial.contentScale,
  };

  return (
    <AnimatedNativeSmoothClipView ref={nativeRef} {...nativeProps}>
      {children}
    </AnimatedNativeSmoothClipView>
  );
});
