import { LegendList } from '@legendapp/list/react-native';
import {
  memo,
  startTransition,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react';
import {
  StyleSheet,
  View,
  type NativeScrollEvent,
  type NativeSyntheticEvent,
} from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import {
  useAnimatedReaction,
  useDerivedValue,
  useSharedValue,
  withTiming,
  type SharedValue,
} from 'react-native-reanimated';
import {
  SmoothClipView,
  useSmoothClipController,
  type ClipGeometry,
  type SmoothClipCompletion,
  type SmoothClipController,
} from 'react-native-smooth-clip-view';
import { scheduleOnUI } from 'react-native-worklets';
import { revealSourceAfterNativeLanding } from '../completeAfterNativeLanding';
import {
  calculateOverlayClipGeometry,
  type OverlayClipGeometryResult,
} from '../overlayClipGeometry';
import {
  CLOSE_TIMING_CONFIG,
  DRAG_THRESHOLD,
  DRAG_TRANSLATE_Y,
  FAST_TIMING,
  IOS_ZOOM_DURATION,
  MAX_TRANSLATE_Y,
  MIN_HEIGHT,
  MIN_WIDTH,
  NATIVE_CLOSE_TIMING,
  NATIVE_FAST_TIMING,
  NATIVE_TIMING,
  OVERLAY_PHASE_CLOSING,
  OVERLAY_PHASE_OPEN,
  OVERLAY_PHASE_OPENING,
  OVERLAY_SOURCE_RADIUS,
  SCREEN_HEIGHT,
  SCREEN_WIDTH,
  TIMING_CONFIG,
  TOP_CLIP_RATIO,
  type OverlayPhase,
} from '../overlayConstants';
import type { Rect, ZoomCity } from '../zoomCities';
import ZoomCityPage from './ZoomCityPage';

type DismissGestureState = Readonly<{
  startX: number;
  startY: number;
  activated: boolean;
}>;

export type SharedElementOverlayItem = Readonly<{ id: string }>;

export type SharedElementPageRenderProps = {
  item: SharedElementOverlayItem;
  index: number;
  originRect: SharedValue<Rect>;
  overlayPhase: SharedValue<OverlayPhase>;
  progress: SharedValue<number>;
};

export type SharedElementPageRenderer = (
  props: SharedElementPageRenderProps
) => ReactNode;

export type SharedElementOverlayChromeProps = Readonly<{
  progress: SharedValue<number>;
  requestClose: () => void;
}>;

type PageProps = SharedElementPageRenderProps & {
  renderPage: SharedElementPageRenderer;
};

function PageContent({
  item,
  index,
  originRect,
  overlayPhase,
  progress,
  renderPage,
}: PageProps) {
  return renderPage({ item, index, originRect, overlayPhase, progress });
}

const PagePlaceholder = memo(function PagePlaceholderView() {
  return <View style={styles.placeholder} />;
});
PagePlaceholder.displayName = 'PagePlaceholder';

// How long a deferred warmup waits before re-checking the overlay phase.
const WARMUP_RETRY_MS = 250;
const CLOSE_COMPLETION_TAG = 1;

type PageWarmupProps = PageProps & {
  dismissGestureState: SharedValue<DismissGestureState>;
  openingIndex: number;
};

const PageWarmup = memo(function PageWarmupView({
  dismissGestureState,
  openingIndex,
  ...props
}: PageWarmupProps) {
  const shouldWarmup = Math.abs(props.index - openingIndex) <= 1;
  const [ready, setReady] = useState(!shouldWarmup);
  const overlayPhase = props.overlayPhase;

  useEffect(() => {
    if (ready) return;
    let timer: ReturnType<typeof setTimeout>;
    // Require TWO consecutive stable checks (phase OPEN, no drag) before
    // mounting. The first fire lands at ~open+416ms — exactly where a
    // human-paced quick close begins — so a single-check mount could land its
    // commit mid-close. The second check 250ms later re-verifies; any drag or
    // close between the two defers.
    let stableChecks = 0;
    const mountWhenOpen = () => {
      // The phase check alone is NOT enough: the dismiss gesture's onStart
      // snaps an interrupted opening straight to OPEN, so a drag begun during
      // the opening would otherwise land this commit mid-drag.
      const phaseNow = overlayPhase.get();
      const dragActive = dismissGestureState.get().activated;
      if (phaseNow === OVERLAY_PHASE_OPEN && !dragActive) {
        stableChecks += 1;
        if (stableChecks >= 2) {
          startTransition(() => {
            setReady(true);
          });
        } else {
          timer = setTimeout(mountWhenOpen, WARMUP_RETRY_MS);
        }
      } else {
        stableChecks = 0;
        timer = setTimeout(mountWhenOpen, WARMUP_RETRY_MS);
      }
    };
    timer = setTimeout(mountWhenOpen, IOS_ZOOM_DURATION + 16); // animation + 1 frame

    return () => {
      clearTimeout(timer);
    };
  }, [dismissGestureState, overlayPhase, ready]);

  if (!ready) return <PagePlaceholder />;
  return <PageContent {...props} />;
});
PageWarmup.displayName = 'PageWarmup';

const PageWrapper = memo(function PageWrapperView({
  dismissGestureState,
  openingIndex,
  ...props
}: PageWarmupProps) {
  if (props.index === openingIndex) {
    return <PageContent {...props} />;
  }
  return (
    <PageWarmup
      {...props}
      dismissGestureState={dismissGestureState}
      openingIndex={openingIndex}
    />
  );
});
PageWrapper.displayName = 'PageWrapper';

type OverlayPagerProps = {
  dismissGestureState: SharedValue<DismissGestureState>;
  items: readonly SharedElementOverlayItem[];
  keyExtractor: (item: SharedElementOverlayItem) => string;
  onMomentumScrollBegin: () => void;
  onMomentumScrollEnd: (event: NativeSyntheticEvent<NativeScrollEvent>) => void;
  onScrollBeginDrag: () => void;
  onScrollEndDrag: () => void;
  openingIndex: number;
  originRect: SharedValue<Rect>;
  overlayPhase: SharedValue<OverlayPhase>;
  progress: SharedValue<number>;
  renderPage: SharedElementPageRenderer;
};

const OverlayPager = memo(function OverlayPagerView({
  dismissGestureState,
  items,
  keyExtractor,
  onMomentumScrollBegin,
  onMomentumScrollEnd,
  onScrollBeginDrag,
  onScrollEndDrag,
  openingIndex,
  originRect,
  overlayPhase,
  progress,
  renderPage,
}: OverlayPagerProps) {
  const renderItem = useCallback(
    ({ item, index }: { item: SharedElementOverlayItem; index: number }) => (
      <PageWrapper
        dismissGestureState={dismissGestureState}
        index={index}
        item={item}
        openingIndex={openingIndex}
        originRect={originRect}
        overlayPhase={overlayPhase}
        progress={progress}
        renderPage={renderPage}
      />
    ),
    [
      dismissGestureState,
      openingIndex,
      originRect,
      overlayPhase,
      progress,
      renderPage,
    ]
  );

  const getFixedItemSize = useCallback(() => SCREEN_WIDTH, []);

  return (
    <LegendList
      data={items as SharedElementOverlayItem[]}
      drawDistance={25}
      estimatedItemSize={SCREEN_WIDTH}
      estimatedListSize={{ width: SCREEN_WIDTH, height: SCREEN_HEIGHT }}
      experimental_exactInitialLayout={{
        width: SCREEN_WIDTH,
        height: SCREEN_HEIGHT,
      }}
      getFixedItemSize={getFixedItemSize}
      horizontal
      initialScrollIndex={openingIndex}
      keyExtractor={keyExtractor}
      onMomentumScrollBegin={onMomentumScrollBegin}
      onMomentumScrollEnd={onMomentumScrollEnd}
      onScrollBeginDrag={onScrollBeginDrag}
      onScrollEndDrag={onScrollEndDrag}
      pagingEnabled
      recycleItems
      renderItem={renderItem}
      showsHorizontalScrollIndicator={false}
      style={styles.pager}
    />
  );
});
OverlayPager.displayName = 'OverlayPager';

type OverlayClipHostProps = {
  children: ReactNode;
  controller: SmoothClipController;
};

function OverlayClipHost({ children, controller }: OverlayClipHostProps) {
  return (
    <SmoothClipView
      controller={controller}
      style={styles.clipHost}
      testID="overlay-smooth-clip-host"
    >
      {children}
    </SmoothClipView>
  );
}

const REVEAL_SHADOW_HIDDEN = {
  color: '#00000000',
  offsetX: 0,
  offsetY: 2,
  blurRadius: 64,
  spreadDistance: 0,
} as const;

const REVEAL_SHADOW_VISIBLE = {
  ...REVEAL_SHADOW_HIDDEN,
  color: '#00000040',
} as const;

function withRevealShadow(
  presentation: OverlayClipGeometryResult,
  visible: boolean
): OverlayClipGeometryResult {
  'worklet';
  return {
    ...presentation,
    boxShadow: visible ? REVEAL_SHADOW_VISIBLE : REVEAL_SHADOW_HIDDEN,
  };
}

function fullscreenPresentation(
  sourceRadius: number,
  maximumDragRadius: number
) {
  'worklet';
  return withRevealShadow(
    calculateOverlayClipGeometry({
      progress: 1,
      originX: 0,
      originY: 0,
      originWidth: SCREEN_WIDTH,
      originHeight: SCREEN_HEIGHT,
      screenWidth: SCREEN_WIDTH,
      screenHeight: SCREEN_HEIGHT,
      translateX: 0,
      translateY: 0,
      dragThreshold: DRAG_THRESHOLD,
      minimumWidth: MIN_WIDTH,
      minimumHeight: MIN_HEIGHT,
      topClipRatio: TOP_CLIP_RATIO,
      dragTranslateY: DRAG_TRANSLATE_Y,
      sourceRadius,
      maximumDragRadius,
    }),
    true
  );
}

// Drag damping shared by onUpdate and the onEnd release-sample adoption.
// Both paths must run the identical math — any divergence between them
// reads as a jump exactly at the release handoff.
function dampDragTranslation(translationX: number, translationY: number) {
  'worklet';
  return {
    x: translationX * 0.7,
    y:
      translationY < 0
        ? translationY * 0.2
        : Math.min(translationY, MAX_TRANSLATE_Y),
  };
}

// The two endpoints of the close: the on-screen release state (drag model at
// full progress with the release translation) and the landing card rect.
function closeEndpoints(
  origin: Rect,
  startX: number,
  startY: number,
  sourceRadius: number,
  maximumDragRadius: number
) {
  'worklet';
  const shared = {
    originX: origin.x,
    originY: origin.y,
    originWidth: origin.w,
    originHeight: origin.h,
    screenWidth: SCREEN_WIDTH,
    screenHeight: SCREEN_HEIGHT,
    dragThreshold: DRAG_THRESHOLD,
    minimumWidth: MIN_WIDTH,
    minimumHeight: MIN_HEIGHT,
    topClipRatio: TOP_CLIP_RATIO,
    dragTranslateY: DRAG_TRANSLATE_Y,
    sourceRadius,
    maximumDragRadius,
  } as const;
  return {
    release: withRevealShadow(
      calculateOverlayClipGeometry({
        ...shared,
        progress: 1,
        translateX: startX,
        translateY: startY,
      }),
      true
    ),
    landing: withRevealShadow(
      calculateOverlayClipGeometry({
        ...shared,
        progress: 0,
        translateX: 0,
        translateY: 0,
      }),
      false
    ),
  };
}

type OverlayProps = {
  hiddenIndex: SharedValue<number>;
  initialIndex: number;
  initialOriginRect: Rect;
  items: readonly SharedElementOverlayItem[];
  keyExtractor: (item: SharedElementOverlayItem) => string;
  maximumDragRadius: number;
  onClosed: () => void;
  onIndexChange: (index: number) => void;
  originRect: SharedValue<Rect>;
  renderOverlayChrome?: (props: SharedElementOverlayChromeProps) => ReactNode;
  renderPage: SharedElementPageRenderer;
  sourceRadius: number;
};

const Overlay = memo(function OverlayView({
  hiddenIndex,
  initialIndex,
  initialOriginRect,
  items,
  keyExtractor,
  maximumDragRadius,
  onClosed,
  onIndexChange,
  originRect,
  renderOverlayChrome,
  renderPage,
  sourceRadius,
}: OverlayProps) {
  const safeInitialIndex =
    items.length === 0
      ? 0
      : Math.min(Math.max(initialIndex, 0), items.length - 1);
  const [openingIndex] = useState(() => safeInitialIndex);

  // Native starts with this exact geometry, preventing a fullscreen flash
  // before the first UI-runtime command arrives.
  const [initialClip] = useState<ClipGeometry>(() => ({
    x: initialOriginRect.x,
    y: initialOriginRect.y,
    width: initialOriginRect.w,
    height: initialOriginRect.h,
    radius: sourceRadius,
  }));
  // The page has no scrollable content, so the child is always "at top". Kept
  // as a shared value so the ported activation gate reads unchanged.
  const childAtTopShared = useSharedValue(true);
  const overlayPhase = useSharedValue<OverlayPhase>(OVERLAY_PHASE_OPENING);
  // One monotonic geometry channel: card → fullscreen when opening and
  // fullscreen → card when closing.
  const progress = useSharedValue(0);

  // Cold state is updated coherently at touch/close boundaries, not per frame.
  const gestureState = useSharedValue<DismissGestureState>({
    startX: 0,
    startY: 0,
    activated: false,
  });
  const translateY = useSharedValue(0);
  const translateX = useSharedValue(0);

  const completeOpening = useCallback(() => {
    'worklet';
    if (overlayPhase.get() !== OVERLAY_PHASE_OPENING) return;

    overlayPhase.set(OVERLAY_PHASE_OPEN);
    hiddenIndex.set(openingIndex);
  }, [hiddenIndex, openingIndex, overlayPhase]);

  const recoverClosing = useCallback(
    (currentUI: SmoothClipController['ui']) => {
      'worklet';
      const visible = currentUI.beginInteraction();
      const fullscreen = fullscreenPresentation(
        sourceRadius,
        maximumDragRadius
      );
      overlayPhase.set(OVERLAY_PHASE_OPEN);
      translateX.set(0);
      translateY.set(0);
      currentUI.setFrame(visible);
      currentUI.beginInteraction();
      const recovery = currentUI.animateTo(fullscreen, NATIVE_FAST_TIMING);
      if (recovery === null) currentUI.setFrame(fullscreen);
      progress.set(withTiming(1, FAST_TIMING));
    },
    [
      maximumDragRadius,
      overlayPhase,
      progress,
      sourceRadius,
      translateX,
      translateY,
    ]
  );

  const onNativeAnimationComplete = useCallback(
    (result: SmoothClipCompletion) => {
      if (result.completionTag === CLOSE_COMPLETION_TAG && result.finished) {
        revealSourceAfterNativeLanding(hiddenIndex, onClosed);
      }
    },
    [hiddenIndex, onClosed]
  );

  const clip = useSmoothClipController(
    {
      clip: initialClip,
      contentTranslateX: initialOriginRect.x,
      contentTranslateY: initialOriginRect.y,
      boxShadow: REVEAL_SHADOW_HIDDEN,
    },
    { onAnimationComplete: onNativeAnimationComplete }
  );

  // Start the opening animation after the native clip host mounts.
  useEffect(() => {
    const openPresentation = withRevealShadow(
      calculateOverlayClipGeometry({
        progress: 1,
        originX: initialOriginRect.x,
        originY: initialOriginRect.y,
        originWidth: initialOriginRect.w,
        originHeight: initialOriginRect.h,
        screenWidth: SCREEN_WIDTH,
        screenHeight: SCREEN_HEIGHT,
        translateX: 0,
        translateY: 0,
        dragThreshold: DRAG_THRESHOLD,
        minimumWidth: MIN_WIDTH,
        minimumHeight: MIN_HEIGHT,
        topClipRatio: TOP_CLIP_RATIO,
        dragTranslateY: DRAG_TRANSLATE_Y,
        sourceRadius,
        maximumDragRadius,
      }),
      true
    );
    scheduleOnUI(() => {
      'worklet';
      const run = clip.ui.animateTo(openPresentation, NATIVE_TIMING);
      if (run === null) {
        clip.ui.setFrame(openPresentation);
        completeOpening();
        return;
      }
      progress.set(
        withTiming(1, TIMING_CONFIG, (finished) => {
          if (finished) completeOpening();
        })
      );
    });
  }, [
    completeOpening,
    clip,
    initialOriginRect,
    maximumDragRadius,
    progress,
    sourceRadius,
  ]);

  // Tracked on the JS side so render never reads a shared value.
  const lastIndexRef = useRef<number>(openingIndex);

  const commitIndexIfChanged = useCallback(
    (index: number) => {
      if (items.length === 0) return;

      const clampedIndex = Math.min(Math.max(index, 0), items.length - 1);
      if (clampedIndex === lastIndexRef.current) return;

      lastIndexRef.current = clampedIndex;
      hiddenIndex.set(clampedIndex);
      onIndexChange(clampedIndex);
    },
    [hiddenIndex, items.length, onIndexChange]
  );

  const overlayGeometry = useDerivedValue(() => {
    const currentProgress = progress.get();
    const origin = originRect.get();

    return calculateOverlayClipGeometry({
      progress: currentProgress,
      originX: origin.x,
      originY: origin.y,
      originWidth: origin.w,
      originHeight: origin.h,
      screenWidth: SCREEN_WIDTH,
      screenHeight: SCREEN_HEIGHT,
      translateX: translateX.get(),
      translateY: translateY.get(),
      dragThreshold: DRAG_THRESHOLD,
      minimumWidth: MIN_WIDTH,
      minimumHeight: MIN_HEIGHT,
      topClipRatio: TOP_CLIP_RATIO,
      dragTranslateY: DRAG_TRANSLATE_Y,
      sourceRadius,
      maximumDragRadius,
    });
  });

  // Only stream frames while a dismiss drag is live. During the open and the
  // close, native runs its own animation and nothing should stream into it.
  useAnimatedReaction(
    () =>
      overlayPhase.get() === OVERLAY_PHASE_OPEN && gestureState.get().activated
        ? overlayGeometry.get()
        : null,
    (presentation) => {
      if (presentation !== null) {
        clip.ui.setFrame(withRevealShadow(presentation, true));
      }
    },
    [clip, gestureState, overlayGeometry, overlayPhase]
  );

  const close = useCallback(() => {
    'worklet';
    if (overlayPhase.get() === OVERLAY_PHASE_CLOSING) return;

    const endpoints = closeEndpoints(
      originRect.get(),
      translateX.get(),
      Math.max(0, translateY.get()),
      sourceRadius,
      maximumDragRadius
    );
    const { release, landing } = endpoints;

    overlayPhase.set(OVERLAY_PHASE_CLOSING);
    clip.ui.setFrame(release);
    clip.ui.beginInteraction();
    const run = clip.ui.animateTo(
      landing,
      NATIVE_CLOSE_TIMING,
      CLOSE_COMPLETION_TAG
    );
    if (run === null) {
      recoverClosing(clip.ui);
      return;
    }
    // Page and chrome visuals mirror native timing, but native completion alone
    // owns teardown so a rejected or interrupted close cannot pop the route.
    progress.set(withTiming(0, CLOSE_TIMING_CONFIG));
  }, [
    clip,
    maximumDragRadius,
    originRect,
    overlayPhase,
    progress,
    recoverClosing,
    sourceRadius,
    translateX,
    translateY,
  ]);

  // Vertical dismiss. Manual activation so the horizontal pager underneath
  // keeps working: any meaningful horizontal movement fails this gesture.
  const dismissGesture = useMemo(
    () =>
      Gesture.Pan()
        .manualActivation(true)
        .onTouchesDown((e, manager) => {
          if (e.numberOfTouches === 1) {
            const touch = e.allTouches[0]!;
            gestureState.set({
              startX: touch.absoluteX,
              startY: touch.absoluteY,
              activated: false,
            });
          } else {
            manager.fail();
          }
        })
        .onTouchesMove((e, manager) => {
          // Never activate while closing: native completion owns teardown, so
          // a new interaction must not replace the close behind its lifecycle.
          if (overlayPhase.get() === OVERLAY_PHASE_CLOSING) {
            manager.fail();
            return;
          }
          const state = gestureState.get();
          if (state.activated) return;
          if (e.numberOfTouches !== 1) {
            manager.fail();
            return;
          }

          const touch = e.allTouches[0]!;
          const deltaX = touch.absoluteX - state.startX;
          const deltaY = touch.absoluteY - state.startY;

          if (Math.abs(deltaX) > 15) {
            manager.fail();
            return;
          }
          if (deltaY < 0) {
            manager.fail();
            return;
          }

          if (deltaY >= 5) {
            if (childAtTopShared.get()) {
              gestureState.set({ ...state, activated: true });
              manager.activate();
            } else {
              manager.fail();
            }
          } else if (Math.abs(deltaX) > 3) {
            manager.fail();
          }
        })
        .onStart(() => {
          // The same native clip owns opening and interaction, so an
          // interrupted opening snaps to fullscreen.
          if (overlayPhase.get() === OVERLAY_PHASE_OPENING) {
            clip.ui.beginInteraction();
            clip.ui.setFrame(
              fullscreenPresentation(sourceRadius, maximumDragRadius)
            );
            progress.set(1);
            completeOpening();
          } else {
            clip.ui.beginInteraction();
          }
        })
        .onUpdate((e) => {
          const damped = dampDragTranslation(e.translationX, e.translationY);
          translateX.set(damped.x);
          translateY.set(damped.y);
        })
        .onEnd((e) => {
          gestureState.set({ ...gestureState.get(), activated: false });
          // Android's ACTION_UP carries a fresher position than the last
          // onUpdate, and a same-batch final onUpdate value never flushes
          // through the now-gated reaction — adopt the release sample so every
          // animation starts from the finger's actual last position.
          const release = dampDragTranslation(e.translationX, e.translationY);
          translateX.set(release.x);
          translateY.set(release.y);
          if (e.translationY > 120 || e.velocityY > 600) {
            close();
          } else {
            const origin = originRect.get();
            const fullscreen = fullscreenPresentation(
              sourceRadius,
              maximumDragRadius
            );
            const releasePresentation = withRevealShadow(
              calculateOverlayClipGeometry({
                progress: progress.get(),
                originX: origin.x,
                originY: origin.y,
                originWidth: origin.w,
                originHeight: origin.h,
                screenWidth: SCREEN_WIDTH,
                screenHeight: SCREEN_HEIGHT,
                translateX: release.x,
                translateY: release.y,
                dragThreshold: DRAG_THRESHOLD,
                minimumWidth: MIN_WIDTH,
                minimumHeight: MIN_HEIGHT,
                topClipRatio: TOP_CLIP_RATIO,
                dragTranslateY: DRAG_TRANSLATE_Y,
                sourceRadius,
                maximumDragRadius,
              }),
              true
            );
            clip.ui.setFrame(releasePresentation);
            clip.ui.beginInteraction();
            clip.ui.animateTo(fullscreen, NATIVE_FAST_TIMING);
            translateX.set(withTiming(0, FAST_TIMING));
            translateY.set(withTiming(0, FAST_TIMING));
            progress.set(withTiming(1, FAST_TIMING));
          }
        }),
    [
      childAtTopShared,
      close,
      completeOpening,
      clip,
      gestureState,
      maximumDragRadius,
      originRect,
      overlayPhase,
      progress,
      sourceRadius,
      translateX,
      translateY,
    ]
  );

  const momentumStartedRef = useRef(false);

  const onScrollBeginDrag = useCallback(() => {
    momentumStartedRef.current = false;
  }, []);

  const onMomentumScrollBegin = useCallback(() => {
    momentumStartedRef.current = true;
  }, []);

  const onScrollEndDrag = useCallback(() => {
    momentumStartedRef.current = false;
  }, []);

  const onMomentumScrollEnd = useCallback(
    (event: NativeSyntheticEvent<NativeScrollEvent>) => {
      momentumStartedRef.current = false;
      const snappedIndex = Math.round(
        event.nativeEvent.contentOffset.x / SCREEN_WIDTH
      );
      commitIndexIfChanged(snappedIndex);
    },
    [commitIndexIfChanged]
  );

  const requestClose = useCallback(() => {
    scheduleOnUI(close);
  }, [close]);

  return (
    <View pointerEvents="box-none" style={styles.zIndexWrapper}>
      <GestureDetector gesture={dismissGesture}>
        <OverlayClipHost controller={clip}>
          <OverlayPager
            dismissGestureState={gestureState}
            items={items}
            keyExtractor={keyExtractor}
            onMomentumScrollBegin={onMomentumScrollBegin}
            onMomentumScrollEnd={onMomentumScrollEnd}
            onScrollBeginDrag={onScrollBeginDrag}
            onScrollEndDrag={onScrollEndDrag}
            openingIndex={openingIndex}
            originRect={originRect}
            overlayPhase={overlayPhase}
            progress={progress}
            renderPage={renderPage}
          />
          {renderOverlayChrome?.({ progress, requestClose })}
        </OverlayClipHost>
      </GestureDetector>
    </View>
  );
});
Overlay.displayName = 'Overlay';

export type SharedElementOverlayContainerProps = {
  activeIndex: number | null;
  hiddenIndex: SharedValue<number>;
  initialOriginRect: Rect | null;
  items: readonly SharedElementOverlayItem[];
  keyExtractor: (item: SharedElementOverlayItem) => string;
  maximumDragRadius?: number;
  onClosed: () => void;
  onIndexChange: (index: number) => void;
  originRect: SharedValue<Rect>;
  renderOverlayChrome?: (props: SharedElementOverlayChromeProps) => ReactNode;
  renderPage: SharedElementPageRenderer;
  sourceRadius: number;
};

export const SharedElementOverlayContainer = memo(
  function SharedElementOverlayContainerView({
    activeIndex,
    hiddenIndex,
    initialOriginRect,
    items,
    keyExtractor,
    maximumDragRadius = 40,
    onClosed,
    onIndexChange,
    originRect,
    renderOverlayChrome,
    renderPage,
    sourceRadius,
  }: SharedElementOverlayContainerProps) {
    if (activeIndex === null || initialOriginRect === null) return null;

    return (
      <Overlay
        hiddenIndex={hiddenIndex}
        initialIndex={activeIndex}
        initialOriginRect={initialOriginRect}
        items={items}
        keyExtractor={keyExtractor}
        maximumDragRadius={maximumDragRadius}
        onClosed={onClosed}
        onIndexChange={onIndexChange}
        originRect={originRect}
        renderOverlayChrome={renderOverlayChrome}
        renderPage={renderPage}
        sourceRadius={sourceRadius}
      />
    );
  }
);
SharedElementOverlayContainer.displayName = 'SharedElementOverlayContainer';

type OverlayContainerProps = Omit<
  SharedElementOverlayContainerProps,
  | 'items'
  | 'keyExtractor'
  | 'maximumDragRadius'
  | 'renderOverlayChrome'
  | 'renderPage'
  | 'sourceRadius'
> & {
  cities: readonly ZoomCity[];
};

const renderZoomCityPage: SharedElementPageRenderer = ({
  item,
  originRect,
  overlayPhase,
  progress,
}) => (
  <ZoomCityPage
    city={item as ZoomCity}
    originRect={originRect}
    overlayPhase={overlayPhase}
    progress={progress}
  />
);

export const OverlayContainer = memo(function OverlayContainerView({
  activeIndex,
  cities,
  hiddenIndex,
  initialOriginRect,
  onClosed,
  onIndexChange,
  originRect,
}: OverlayContainerProps) {
  return (
    <SharedElementOverlayContainer
      activeIndex={activeIndex}
      hiddenIndex={hiddenIndex}
      initialOriginRect={initialOriginRect}
      items={cities}
      keyExtractor={(item) => item.id}
      onClosed={onClosed}
      onIndexChange={onIndexChange}
      originRect={originRect}
      renderPage={renderZoomCityPage}
      sourceRadius={OVERLAY_SOURCE_RADIUS}
    />
  );
});
OverlayContainer.displayName = 'OverlayContainer';

const styles = StyleSheet.create({
  zIndexWrapper: {
    height: SCREEN_HEIGHT,
    left: 0,
    position: 'absolute',
    top: 0,
    width: SCREEN_WIDTH,
    zIndex: 999,
  },
  clipHost: {
    height: SCREEN_HEIGHT,
    left: 0,
    position: 'absolute',
    top: 0,
    width: SCREEN_WIDTH,
  },
  pager: { flex: 1 },
  placeholder: { height: SCREEN_HEIGHT, width: SCREEN_WIDTH },
});
