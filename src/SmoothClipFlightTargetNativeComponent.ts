import {
  codegenNativeComponent,
  type CodegenTypes,
  type HostComponent,
  type ViewProps,
} from 'react-native';

export interface NativeProps extends ViewProps {
  /** The `flight` tag of the SmoothClipView hosts that land on this view. */
  flightTag: string;
  /** While false, a flight that lands here keeps its own pixels on screen. */
  ready?: CodegenTypes.WithDefault<boolean, true>;
}

export default codegenNativeComponent<NativeProps>(
  'SmoothClipFlightTarget'
) as HostComponent<NativeProps>;
