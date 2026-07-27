import {
  codegenNativeCommands,
  codegenNativeComponent,
  type CodegenTypes,
  type HostComponent,
  type ViewProps,
} from 'react-native';

export interface NativeProps extends ViewProps {
  driverId: CodegenTypes.Double;
  initialClipX: CodegenTypes.Double;
  initialClipY: CodegenTypes.Double;
  initialClipWidth: CodegenTypes.Double;
  initialClipHeight: CodegenTypes.Double;
  initialClipRadius: CodegenTypes.Double;
  initialContentTranslateX: CodegenTypes.Double;
  initialContentTranslateY: CodegenTypes.Double;
}

interface NativeCommands {
  setClipGeometry: (
    viewRef: React.ElementRef<HostComponent<NativeProps>>,
    x: CodegenTypes.Double,
    y: CodegenTypes.Double,
    width: CodegenTypes.Double,
    height: CodegenTypes.Double,
    radius: CodegenTypes.Double
  ) => void;
  setClipPresentation: (
    viewRef: React.ElementRef<HostComponent<NativeProps>>,
    x: CodegenTypes.Double,
    y: CodegenTypes.Double,
    width: CodegenTypes.Double,
    height: CodegenTypes.Double,
    radius: CodegenTypes.Double,
    contentTranslateX: CodegenTypes.Double,
    contentTranslateY: CodegenTypes.Double
  ) => void;
}

export const Commands: NativeCommands = codegenNativeCommands<NativeCommands>({
  supportedCommands: ['setClipGeometry', 'setClipPresentation'],
});

export default codegenNativeComponent<NativeProps>(
  'SmoothClipView'
) as HostComponent<NativeProps>;
