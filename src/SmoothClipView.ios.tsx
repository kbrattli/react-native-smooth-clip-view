/* eslint-disable no-bitwise -- color channels use packed RRGGBBAA integers */
import {
  forwardRef,
  useEffect,
  type ComponentRef,
  type ForwardedRef,
  type ReactElement,
  type ReactNode,
} from 'react';
import { StyleSheet, type ViewProps, type ViewStyle } from 'react-native';
import type { SmoothClipController } from './controllerTypes';
import { getControllerRef, unwrapSmoothClipRef } from './controllerInternals';
import NativeSmoothClipView, {
  type NativeProps,
} from './SmoothClipViewNativeComponent';

export type SmoothClipViewProps = ViewProps & {
  controller: SmoothClipController;
  children?: ReactNode;
};

let reportedIndependentShadow = false;
const mountedControllers = new WeakMap<SmoothClipController, number>();

function useSingleControllerHost(controller: SmoothClipController): void {
  useEffect(() => {
    const mounted = mountedControllers.get(controller) ?? 0;
    if (__DEV__ && mounted > 0) {
      throw new Error(
        '[SmoothClipView] One controller cannot drive two mounted hosts. Create one controller per SmoothClipView.'
      );
    }
    mountedControllers.set(controller, mounted + 1);
    return () => {
      const current = mountedControllers.get(controller) ?? 1;
      if (current <= 1) mountedControllers.delete(controller);
      else mountedControllers.set(controller, current - 1);
    };
  }, [controller]);
}

function filterContainsDropShadow(filter: ViewStyle['filter']): boolean {
  if (typeof filter === 'string') return /drop-shadow\s*\(/i.test(filter);
  return (
    Array.isArray(filter) &&
    filter.some(
      (entry) =>
        typeof entry === 'object' && entry !== null && 'dropShadow' in entry
    )
  );
}

function removeDropShadowFilter(
  filter: ViewStyle['filter']
): ViewStyle['filter'] | undefined {
  if (typeof filter === 'string') {
    const remaining = filter
      .replace(/drop-shadow\((?:[^()]|\([^()]*\))*\)/gi, '')
      .trim();
    return remaining === '' ? undefined : remaining;
  }
  if (Array.isArray(filter)) {
    const remaining = filter.filter(
      (entry) =>
        !(typeof entry === 'object' && entry !== null && 'dropShadow' in entry)
    );
    return remaining.length === 0
      ? undefined
      : (remaining as ViewStyle['filter']);
  }
  return filter;
}

/** Prevents React Native from installing a second, aperture-independent shadow. */
export function sanitizeSmoothClipStyle(
  style: ViewProps['style']
): ViewProps['style'] {
  const flat = StyleSheet.flatten(style);
  if (flat == null) return style;
  const hasIndependentShadow =
    flat.boxShadow !== undefined ||
    flat.shadowColor !== undefined ||
    flat.shadowOffset !== undefined ||
    flat.shadowOpacity !== undefined ||
    flat.shadowRadius !== undefined ||
    flat.elevation !== undefined ||
    filterContainsDropShadow(flat.filter);
  if (!hasIndependentShadow) return style;
  if (__DEV__ && !reportedIndependentShadow) {
    reportedIndependentShadow = true;
    console.error(
      '[SmoothClipView] Shadow style properties are not rendered on the host. ' +
        'Put the shadow in SmoothClipPresentation.boxShadow so it follows the clip aperture.'
    );
  }
  const sanitized: Record<string, unknown> = { ...flat };
  delete sanitized.boxShadow;
  delete sanitized.shadowColor;
  delete sanitized.shadowOffset;
  delete sanitized.shadowOpacity;
  delete sanitized.shadowRadius;
  delete sanitized.elevation;
  if (filterContainsDropShadow(sanitized.filter as ViewStyle['filter'])) {
    const filter = removeDropShadowFilter(
      sanitized.filter as ViewStyle['filter']
    );
    if (filter === undefined) delete sanitized.filter;
    else sanitized.filter = filter;
  }
  return sanitized as ViewStyle;
}

export function renderSmoothClipView(
  { controller, children, style, ...viewProps }: SmoothClipViewProps,
  forwardedRef: ForwardedRef<ComponentRef<typeof NativeSmoothClipView>>
): ReactElement {
  const { ref, initialFrame: canonical } = getControllerRef(controller);
  const driverId = unwrapSmoothClipRef(ref)?.id ?? 0;
  const { clip } = canonical;
  const shadow = canonical.boxShadow;
  const color = (shadow?.color as unknown as number) ?? 0;
  const nativeProps: NativeProps = {
    ...viewProps,
    style: sanitizeSmoothClipStyle(style),
    driverId,
    initialClipX: clip.x,
    initialClipY: clip.y,
    initialClipWidth: clip.width,
    initialClipHeight: clip.height,
    initialClipTopLeftRadius: clip.topLeftRadius,
    initialClipTopRightRadius: clip.topRightRadius,
    initialClipBottomRightRadius: clip.bottomRightRadius,
    initialClipBottomLeftRadius: clip.bottomLeftRadius,
    initialClipCurve: clip.curve === 'continuous' ? 1 : 0,
    initialContentTranslateX: canonical.contentTranslateX,
    initialContentTranslateY: canonical.contentTranslateY,
    initialContentScale: canonical.contentScale,
    initialClipBoxShadowEnabled: shadow !== undefined,
    initialClipBoxShadowRed: ((color >>> 24) & 0xff) / 255,
    initialClipBoxShadowGreen: ((color >>> 16) & 0xff) / 255,
    initialClipBoxShadowBlue: ((color >>> 8) & 0xff) / 255,
    initialClipBoxShadowAlpha: (color & 0xff) / 255,
    initialClipBoxShadowOffsetX: shadow?.offsetX ?? 0,
    initialClipBoxShadowOffsetY: shadow?.offsetY ?? 0,
    initialClipBoxShadowBlurRadius: shadow?.blurRadius ?? 0,
    initialClipBoxShadowSpreadDistance: shadow?.spreadDistance ?? 0,
  };

  return (
    <NativeSmoothClipView ref={forwardedRef} {...nativeProps}>
      {children}
    </NativeSmoothClipView>
  );
}

export const SmoothClipView = forwardRef<
  ComponentRef<typeof NativeSmoothClipView>,
  SmoothClipViewProps
>(function SmoothClipViewComponent(props, forwardedRef) {
  useSingleControllerHost(props.controller);
  return renderSmoothClipView(props, forwardedRef);
});
