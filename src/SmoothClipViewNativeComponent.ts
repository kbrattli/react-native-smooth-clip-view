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
  initialClipTopLeftRadius: CodegenTypes.Double;
  initialClipTopRightRadius: CodegenTypes.Double;
  initialClipBottomRightRadius: CodegenTypes.Double;
  initialClipBottomLeftRadius: CodegenTypes.Double;
  initialClipCurve: CodegenTypes.Int32;
  initialContentTranslateX: CodegenTypes.Double;
  initialContentTranslateY: CodegenTypes.Double;
  initialContentScale: CodegenTypes.Double;
  initialClipBoxShadowEnabled: boolean;
  initialClipBoxShadowRed: CodegenTypes.Double;
  initialClipBoxShadowGreen: CodegenTypes.Double;
  initialClipBoxShadowBlue: CodegenTypes.Double;
  initialClipBoxShadowAlpha: CodegenTypes.Double;
  initialClipBoxShadowOffsetX: CodegenTypes.Double;
  initialClipBoxShadowOffsetY: CodegenTypes.Double;
  initialClipBoxShadowBlurRadius: CodegenTypes.Double;
  initialClipBoxShadowSpreadDistance: CodegenTypes.Double;
}

interface NativeCommands {
  setClipPresentation: (
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
    contentScale: CodegenTypes.Double,
    shadowEnabled: boolean,
    shadowRed: CodegenTypes.Double,
    shadowGreen: CodegenTypes.Double,
    shadowBlue: CodegenTypes.Double,
    shadowAlpha: CodegenTypes.Double,
    shadowOffsetX: CodegenTypes.Double,
    shadowOffsetY: CodegenTypes.Double,
    shadowBlurRadius: CodegenTypes.Double,
    shadowSpreadDistance: CodegenTypes.Double
  ) => void;
}

export const Commands: NativeCommands = codegenNativeCommands<NativeCommands>({
  supportedCommands: ['setClipPresentation'],
});

export default codegenNativeComponent<NativeProps>(
  'SmoothClipView'
) as HostComponent<NativeProps>;
