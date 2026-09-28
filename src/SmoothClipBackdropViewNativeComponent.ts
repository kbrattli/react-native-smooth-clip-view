import {
  codegenNativeComponent,
  type CodegenTypes,
  type HostComponent,
  type ViewProps,
} from 'react-native';

export interface NativeProps extends ViewProps {
  /** The controller (driver) whose `backdrop` channel translates this view. */
  driverId: CodegenTypes.Double;
}

export default codegenNativeComponent<NativeProps>(
  'SmoothClipBackdropView'
) as HostComponent<NativeProps>;
