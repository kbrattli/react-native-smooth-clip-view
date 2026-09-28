import {
  forwardRef,
  type ComponentRef,
  type ForwardedRef,
  type ReactElement,
  type ReactNode,
} from 'react';
import type { ViewProps } from 'react-native';
import type { SmoothClipController } from './controllerTypes';
import { getControllerRef, unwrapSmoothClipRef } from './controllerInternals';
import NativeSmoothClipBackdropView from './SmoothClipBackdropViewNativeComponent';

export type SmoothClipBackdropViewProps = ViewProps & {
  controller: SmoothClipController;
  children?: ReactNode;
};

export function renderSmoothClipBackdropView(
  { controller, children, ...viewProps }: SmoothClipBackdropViewProps,
  forwardedRef: ForwardedRef<ComponentRef<typeof NativeSmoothClipBackdropView>>
): ReactElement {
  const { ref } = getControllerRef(controller);
  const driverId = unwrapSmoothClipRef(ref)?.id ?? 0;
  return (
    <NativeSmoothClipBackdropView
      ref={forwardedRef}
      {...viewProps}
      driverId={driverId}
    >
      {children}
    </NativeSmoothClipBackdropView>
  );
}

/**
 * A view translated by its controller's `backdrop` channel: every `setFrame`
 * and native run that moves the clip moves this view's content by the
 * presentation's `backdrop.translateX/Y` in the same native frame, with the
 * same clock and epoch as the aperture. Content that must stay locked to the
 * window (a canvas centred in it) belongs here rather than on a Reanimated
 * mapper, which can land a frame later than the clip.
 *
 * Any number of backdrop views may bind to one controller, anywhere in the
 * tree. One that mounts while a run is in flight adopts the driver's current
 * value and follows from the next run. The channel owns the content's
 * transform: do not put a `transform` style on this view.
 */
export const SmoothClipBackdropView = forwardRef<
  ComponentRef<typeof NativeSmoothClipBackdropView>,
  SmoothClipBackdropViewProps
>(function SmoothClipBackdropViewComponent(props, forwardedRef) {
  return renderSmoothClipBackdropView(props, forwardedRef);
});
