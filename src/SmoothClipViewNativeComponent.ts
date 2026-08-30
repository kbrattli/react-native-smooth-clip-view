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
  presentationVersion: CodegenTypes.Int32;
  initialClipTopLeftRadius: CodegenTypes.Double;
  initialClipTopRightRadius: CodegenTypes.Double;
  initialClipBottomRightRadius: CodegenTypes.Double;
  initialClipBottomLeftRadius: CodegenTypes.Double;
  initialClipCurve: CodegenTypes.Int32;
  initialContentTranslateX: CodegenTypes.Double;
  initialContentTranslateY: CodegenTypes.Double;
  initialContentScale: CodegenTypes.Double;
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
  setClipPresentationV2: (
    viewRef: React.ElementRef<HostComponent<NativeProps>>,
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
    contentScale: CodegenTypes.Double
  ) => void;
}

export const Commands: NativeCommands = codegenNativeCommands<NativeCommands>({
  supportedCommands: [
    'setClipGeometry',
    'setClipPresentation',
    'setClipPresentationV2',
  ],
});

export default codegenNativeComponent<NativeProps>(
  'SmoothClipView'
) as HostComponent<NativeProps>;
