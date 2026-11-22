import {
  forwardRef,
  type ComponentRef,
  type ForwardRefExoticComponent,
  type ReactNode,
  type RefAttributes,
} from 'react';
import type { HostInstance, ViewProps } from 'react-native';
import NativeSmoothClipFlightTarget from './SmoothClipFlightTargetNativeComponent';

export type SmoothClipFlightTargetProps = ViewProps & {
  /** Pairs this view with the SmoothClipView hosts whose `flight` is this tag. */
  tag: string;
  /**
   * Default true. While false, a flight that lands on this view keeps its own
   * content on screen at the destination instead of revealing this view: for
   * example until a full-resolution image has loaded. Setting it to true
   * reveals this view in the next frame.
   */
  ready?: boolean;
  children?: ReactNode;
};

/**
 * The other endpoint of a flight. While a SmoothClipView with the same
 * `flight` tag is airborne, this view's content is hidden natively (its React
 * styles are never touched), from the frame the flight starts or the frame
 * this view mounts, whichever is later. The transaction that lands the flight
 * reveals it, so no frame shows both or neither.
 */
export const SmoothClipFlightTarget: ForwardRefExoticComponent<
  SmoothClipFlightTargetProps & RefAttributes<HostInstance>
> = forwardRef<
  ComponentRef<typeof NativeSmoothClipFlightTarget>,
  SmoothClipFlightTargetProps
>(function SmoothClipFlightTargetComponent(
  { tag, ready = true, ...viewProps },
  forwardedRef
) {
  return (
    <NativeSmoothClipFlightTarget
      {...viewProps}
      flightTag={tag}
      ready={ready}
      ref={forwardedRef}
    />
  );
});
