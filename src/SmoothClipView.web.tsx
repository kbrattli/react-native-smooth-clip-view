import {
  forwardRef,
  type ComponentRef,
  type ForwardedRef,
  type ReactNode,
  useCallback,
  useEffect,
  useRef,
} from 'react';
import { type ViewProps, type ViewStyle } from 'react-native';
import Animated, {
  useAnimatedReaction,
  useAnimatedStyle,
  useSharedValue,
} from 'react-native-reanimated';
import type { SmoothClipDriver } from './driverTypes';
import { getDriverState, registerDriverViewReadiness } from './driverState';
import {
  canonicalizeClipPresentation,
  clipPresentationEquals,
  isFiniteClipPresentation,
  type ClipBounds,
} from './geometry';
import {
  observeWebHostReadiness,
  resolveWebHost,
  type WebHost,
} from './webHostReadiness';
import { createWebClipPath, WEB_CONTENT_CONTAINER_STYLE } from './webClipPath';

export type SmoothClipViewProps = ViewProps & {
  driver: SmoothClipDriver;
  children?: ReactNode;
};

function setForwardedRef<T>(ref: ForwardedRef<T>, value: T | null): void {
  if (typeof ref === 'function') ref(value);
  else if (ref !== null) ref.current = value;
}

const fullSizeContentStyle =
  WEB_CONTENT_CONTAINER_STYLE as unknown as ViewStyle;

/** Fixed-layout CSS fallback. */
export const SmoothClipView = forwardRef<
  ComponentRef<typeof Animated.View>,
  SmoothClipViewProps
>(function SmoothClipViewComponent(
  { driver, children, style, ...viewProps },
  forwardedRef
) {
  const { initialPresentation, source } = getDriverState(driver);
  const hostRef = useRef<WebHost | null>(null);
  const bounds = useSharedValue<ClipBounds>({ width: 0, height: 0 });
  const composedRef = useCallback(
    (value: ComponentRef<typeof Animated.View> | null) => {
      hostRef.current = resolveWebHost(value);
      setForwardedRef(forwardedRef, value);
    },
    [forwardedRef]
  );

  useEffect(() => {
    const registration = registerDriverViewReadiness(driver, false);
    const host = hostRef.current;
    if (host === null) return registration.unregister;
    const stopObserving = observeWebHostReadiness(host, (nextBounds, ready) => {
      if (
        bounds.value.width !== nextBounds.width ||
        bounds.value.height !== nextBounds.height
      ) {
        bounds.value = nextBounds;
      }
      registration.setReady(ready);
    });
    return () => {
      stopObserving();
      registration.unregister();
    };
  }, [bounds, driver]);

  const canonicalInitial = canonicalizeClipPresentation(initialPresentation)!;
  const acceptedPresentation = useSharedValue(canonicalInitial);
  const initialClipStyle = {
    clipPath: createWebClipPath(canonicalInitial.clip, bounds.value),
    overflow: 'hidden',
  } as unknown as ViewStyle;

  useAnimatedReaction(
    () => source.value,
    (presentation, previousPresentation) => {
      if (
        isFiniteClipPresentation(presentation) &&
        !clipPresentationEquals(previousPresentation, presentation)
      ) {
        const canonical = canonicalizeClipPresentation(presentation);
        if (canonical !== null) acceptedPresentation.value = canonical;
      }
    },
    [source, acceptedPresentation]
  );

  const clipStyle = useAnimatedStyle(() => ({
    clipPath: createWebClipPath(acceptedPresentation.value.clip, bounds.value),
    overflow: 'hidden',
  }));

  const contentStyle = useAnimatedStyle(() => ({
    transform: [
      { translateX: acceptedPresentation.value.contentTranslateX },
      { translateY: acceptedPresentation.value.contentTranslateY },
      { scale: acceptedPresentation.value.contentScale },
    ],
  }));

  return (
    <Animated.View
      {...viewProps}
      ref={composedRef}
      style={[style, initialClipStyle, clipStyle]}
    >
      <Animated.View style={[fullSizeContentStyle, contentStyle]}>
        {children}
      </Animated.View>
    </Animated.View>
  );
});
