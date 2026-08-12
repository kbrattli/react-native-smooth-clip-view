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
import Animated, {
  useAnimatedReaction,
  useAnimatedStyle,
  useDerivedValue,
  useSharedValue,
  withTiming,
  type DerivedValue,
  type SharedValue,
} from 'react-native-reanimated';
import {
  SmoothClipView,
  useSmoothClipDriver,
  type ClipGeometry,
  type SmoothClipDriver,
} from 'react-native-smooth-clip-view';
import { scheduleOnRN, scheduleOnUI } from 'react-native-worklets';
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
  cityKeyExtractor,
  type OverlayPhase,
} from '../overlayConstants';
import type { Rect, ZoomCity } from '../zoomCities';
import ZoomCityPage from './ZoomCityPage';

type CloseStart = Readonly<{ x: number; y: number }>;
type DismissGestureState = Readonly<{
  startX: number;
  startY: number;
  activated: boolean;
}>;

type PageProps = {
  city: ZoomCity;
  index: number;
  originRect: SharedValue<Rect>;
  overlayPhase: SharedValue<OverlayPhase>;
  progress: SharedValue<number>;
};

const PagePlaceholder = memo(function PagePlaceholderView() {
  return <View style={styles.placeholder} />;
});
PagePlaceholder.displayName = 'PagePlaceholder';

// How long a deferred warmup waits before re-checking the overlay phase.
const WARMUP_RETRY_MS = 250;

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
  return <ZoomCityPage {...props} />;
});
PageWarmup.displayName = 'PageWarmup';

const PageWrapper = memo(function PageWrapperView({
  dismissGestureState,
  openingIndex,
  ...props
}: PageWarmupProps) {
  if (props.index === openingIndex) {
    return <ZoomCityPage {...props} />;
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
  cities: readonly ZoomCity[];
  dismissGestureState: SharedValue<DismissGestureState>;
  onMomentumScrollBegin: () => void;
  onMomentumScrollEnd: (event: NativeSyntheticEvent<NativeScrollEvent>) => void;
  onScrollBeginDrag: () => void;
  onScrollEndDrag: () => void;
  openingIndex: number;
  originRect: SharedValue<Rect>;
  overlayPhase: SharedValue<OverlayPhase>;
  progress: SharedValue<number>;
};

const OverlayPager = memo(function OverlayPagerView({
  cities,
  dismissGestureState,
  onMomentumScrollBegin,
  onMomentumScrollEnd,
  onScrollBeginDrag,
  onScrollEndDrag,
  openingIndex,
  originRect,
  overlayPhase,
  progress,
}: OverlayPagerProps) {
  const renderItem = useCallback(
    ({ item: city, index }: { item: ZoomCity; index: number }) => (
      <PageWrapper
        city={city}
        dismissGestureState={dismissGestureState}
        index={index}
        openingIndex={openingIndex}
        originRect={originRect}
        overlayPhase={overlayPhase}
        progress={progress}
      />
    ),
    [dismissGestureState, openingIndex, originRect, overlayPhase, progress]
  );

  const getFixedItemSize = useCallback(() => SCREEN_WIDTH, []);

  return (
    <LegendList
      data={cities as ZoomCity[]}
      drawDistance={25}
      estimatedItemSize={SCREEN_WIDTH}
      estimatedListSize={{ width: SCREEN_WIDTH, height: SCREEN_HEIGHT }}
      getFixedItemSize={getFixedItemSize}
      horizontal
      initialScrollIndex={openingIndex}
      keyExtractor={cityKeyExtractor}
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
  driver: SmoothClipDriver;
  overlayGeometry: DerivedValue<OverlayClipGeometryResult>;
};

// The native presentation carries clip + content TRANSLATION only — it has no
// scale channel — so the drag's content zoom is the one channel that has to
// ride an RN transform. Keep it that way: anything else on this style would put
// the clip and the content on two different clocks.
function OverlayClipHost({
  children,
  driver,
  overlayGeometry,
}: OverlayClipHostProps) {
  const contentStyle = useAnimatedStyle(() => ({
    transform: [{ scale: overlayGeometry.get().contentScale }],
  }));

  return (
    <SmoothClipView
      driver={driver}
      style={styles.maximumClipHost}
      testID="overlay-smooth-clip-host"
    >
      <Animated.View
        style={[styles.maximumClipHost, contentStyle]}
        testID="overlay-smooth-clip-content"
      >
        {children}
      </Animated.View>
    </SmoothClipView>
  );
}

const FULLSCREEN_PRESENTATION = calculateOverlayClipGeometry({
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
  sourceRadius: OVERLAY_SOURCE_RADIUS,
});

function applyPresentationScalars(
  driver: SmoothClipDriver,
  presentation: OverlayClipGeometryResult
) {
  'worklet';
  driver.ui.setScalars(
    presentation.clip.x,
    presentation.clip.y,
    presentation.clip.width,
    presentation.clip.height,
    presentation.clip.radius,
    presentation.contentTranslateX,
    presentation.contentTranslateY
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

const CLOSE_KEYFRAME_COUNT = 31;

function mixChannel(from: number, to: number, fraction: number) {
  'worklet';
  return from + (to - from) * fraction;
}

// Every clip channel advanced by the same eased fraction. Re-deriving each
// frame through the drag model with decayed inputs would make the size channels
// carry a p² term (drag shrink = dragProgress(p) x base(p), both ∝ p) while x/y
// decayed ∝ p — the window would visibly translate home faster than it resized.
// Interpolating the OUTPUT presentations treats all channels equally.
function mixPresentation(
  from: OverlayClipGeometryResult,
  to: OverlayClipGeometryResult,
  fraction: number
): OverlayClipGeometryResult {
  'worklet';
  return {
    clip: {
      x: mixChannel(from.clip.x, to.clip.x, fraction),
      y: mixChannel(from.clip.y, to.clip.y, fraction),
      width: mixChannel(from.clip.width, to.clip.width, fraction),
      height: mixChannel(from.clip.height, to.clip.height, fraction),
      radius: mixChannel(from.clip.radius, to.clip.radius, fraction),
    },
    contentTranslateX: mixChannel(
      from.contentTranslateX,
      to.contentTranslateX,
      fraction
    ),
    contentTranslateY: mixChannel(
      from.contentTranslateY,
      to.contentTranslateY,
      fraction
    ),
    // The RN-side zoom rides the same eased fraction as the natively animated
    // clip channels, so the content unzooms in step with its window.
    contentScale: mixChannel(from.contentScale, to.contentScale, fraction),
    contentVisibleHeight: mixChannel(
      from.contentVisibleHeight,
      to.contentVisibleHeight,
      fraction
    ),
  };
}

// The two endpoints of the close: the on-screen release state (drag model at
// full progress with the release translation) and the landing card rect.
function closeEndpoints(origin: Rect, start: CloseStart) {
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
    sourceRadius: OVERLAY_SOURCE_RADIUS,
  } as const;
  return {
    release: calculateOverlayClipGeometry({
      ...shared,
      progress: 1,
      translateX: start.x,
      translateY: start.y,
    }),
    landing: calculateOverlayClipGeometry({
      ...shared,
      progress: 0,
      translateX: 0,
      translateY: 0,
    }),
  };
}

function createCloseKeyframes(origin: Rect, start: CloseStart) {
  'worklet';
  const { release, landing } = closeEndpoints(origin, start);
  const frames = [];
  for (let index = 0; index < CLOSE_KEYFRAME_COUNT; index += 1) {
    const offset = index / (CLOSE_KEYFRAME_COUNT - 1);
    const inverse = 1 - offset;
    // Same ease-out-cubic clock as CLOSE_TIMING_CONFIG's easing:
    // eased = 1 − (1 − t)³, so frame 0 is exactly the release state and the JS
    // progress channel stays phase-locked.
    frames.push({
      offset,
      presentation: mixPresentation(
        release,
        landing,
        1 - inverse * inverse * inverse
      ),
    });
  }
  return frames;
}

type OverlayProps = {
  cities: readonly ZoomCity[];
  hiddenIndex: SharedValue<number>;
  initialIndex: number;
  initialOriginRect: Rect;
  onClosed: () => void;
  onIndexChange: (index: number) => void;
  originRect: SharedValue<Rect>;
};

const Overlay = memo(function OverlayView({
  cities,
  hiddenIndex,
  initialIndex,
  initialOriginRect,
  onClosed,
  onIndexChange,
  originRect,
}: OverlayProps) {
  const safeInitialIndex =
    cities.length === 0
      ? 0
      : Math.min(Math.max(initialIndex, 0), cities.length - 1);
  const [openingIndex] = useState(() => safeInitialIndex);

  // Native starts with this exact geometry, preventing a fullscreen flash
  // before the first UI-runtime command arrives.
  const [initialClip] = useState<ClipGeometry>(() => ({
    x: initialOriginRect.x,
    y: initialOriginRect.y,
    width: initialOriginRect.w,
    height: initialOriginRect.h,
    radius: OVERLAY_SOURCE_RADIUS,
  }));
  const driver = useSmoothClipDriver({
    clip: initialClip,
    contentTranslateX: initialOriginRect.x,
    contentTranslateY: initialOriginRect.y,
  });

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

  const completeOpening = useCallback(() => {
    'worklet';
    if (overlayPhase.get() !== OVERLAY_PHASE_OPENING) return;

    overlayPhase.set(OVERLAY_PHASE_OPEN);
    hiddenIndex.set(openingIndex);
  }, [hiddenIndex, openingIndex, overlayPhase]);

  // Start the opening animation after the native clip host mounts.
  useEffect(() => {
    const openPresentation = calculateOverlayClipGeometry({
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
      sourceRadius: OVERLAY_SOURCE_RADIUS,
    });
    scheduleOnUI(() => {
      'worklet';
      driver.ui.animateTo(openPresentation, NATIVE_TIMING);
      progress.set(
        withTiming(1, TIMING_CONFIG, (finished) => {
          if (finished) {
            completeOpening();
          }
        })
      );
    });
  }, [completeOpening, driver, initialOriginRect, progress]);

  // Tracked on the JS side so render never reads a shared value.
  const lastIndexRef = useRef<number>(openingIndex);

  const translateY = useSharedValue(0);
  const translateX = useSharedValue(0);
  const closeStart = useSharedValue<CloseStart>({ x: 0, y: 0 });

  const commitIndexIfChanged = useCallback(
    (index: number) => {
      if (cities.length === 0) return;

      const clampedIndex = Math.min(Math.max(index, 0), cities.length - 1);
      if (clampedIndex === lastIndexRef.current) return;

      lastIndexRef.current = clampedIndex;
      hiddenIndex.set(clampedIndex);
      onIndexChange(clampedIndex);
    },
    [cities.length, hiddenIndex, onIndexChange]
  );

  const overlayGeometry = useDerivedValue(() => {
    const currentProgress = progress.get();
    const origin = originRect.get();

    if (overlayPhase.get() === OVERLAY_PHASE_CLOSING) {
      // Mirror the native close keyframes: output-space mix so every channel
      // paces identically. progress runs withTiming(0) on the same
      // ease-out-cubic clock, so 1 − progress IS the keyframes' eased fraction.
      const { release, landing } = closeEndpoints(origin, closeStart.get());
      return mixPresentation(release, landing, 1 - currentProgress);
    }

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
      sourceRadius: OVERLAY_SOURCE_RADIUS,
    });
  });

  // Only stream scalars while a dismiss drag is live. During the open and the
  // close, native runs its own animation and nothing should stream into it.
  useAnimatedReaction(
    () =>
      overlayPhase.get() === OVERLAY_PHASE_OPEN && gestureState.get().activated
        ? overlayGeometry.get()
        : null,
    (presentation) => {
      if (presentation !== null) {
        applyPresentationScalars(driver, presentation);
      }
    },
    [driver, gestureState, overlayGeometry, overlayPhase]
  );

  const close = useCallback(() => {
    'worklet';
    if (overlayPhase.get() === OVERLAY_PHASE_CLOSING) return;

    overlayPhase.set(OVERLAY_PHASE_CLOSING);
    closeStart.set({
      x: translateX.get(),
      y: Math.max(0, translateY.get()),
    });
    const frames = createCloseKeyframes(originRect.get(), closeStart.get());
    const target = frames[frames.length - 1]?.presentation;
    if (target) {
      driver.ui.animateTo(target, {
        type: 'keyframes',
        duration: CLOSE_TIMING_CONFIG.duration,
        frames,
        // Keyframes interpolate absolutely, and the final gesture value may
        // never have flushed through the gated reaction — seed frame 0 so the
        // animation continues from what is on screen.
        from: frames[0]?.presentation,
      });
    }

    progress.set(
      withTiming(0, CLOSE_TIMING_CONFIG, (finished) => {
        if (finished) {
          hiddenIndex.set(-1);
          scheduleOnRN(onClosed);
        }
      })
    );
  }, [
    closeStart,
    driver,
    hiddenIndex,
    onClosed,
    originRect,
    overlayPhase,
    progress,
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
          // Never activate while closing: a mid-close grab would
          // beginInteraction (freezing the native close) while the close's
          // progress timing keeps running, and a gentle release would then
          // interrupt that timing — its finished:false callback skips the
          // teardown and the phase stays CLOSING forever.
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
            driver.ui.cancel(undefined, 'target');
            progress.set(1);
            completeOpening();
          } else {
            driver.ui.beginInteraction();
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
            driver.ui.animateTo(FULLSCREEN_PRESENTATION, {
              ...NATIVE_FAST_TIMING,
              // Start from the release sample — the gated reaction never
              // flushed it natively.
              from: calculateOverlayClipGeometry({
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
                sourceRadius: OVERLAY_SOURCE_RADIUS,
              }),
            });
            translateX.set(withTiming(0, FAST_TIMING));
            translateY.set(withTiming(0, FAST_TIMING));
            progress.set(withTiming(1, FAST_TIMING));
          }
        }),
    [
      childAtTopShared,
      close,
      completeOpening,
      driver,
      gestureState,
      originRect,
      overlayPhase,
      progress,
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

  return (
    <View pointerEvents="box-none" style={styles.zIndexWrapper}>
      <GestureDetector gesture={dismissGesture}>
        <OverlayClipHost driver={driver} overlayGeometry={overlayGeometry}>
          <OverlayPager
            cities={cities}
            dismissGestureState={gestureState}
            onMomentumScrollBegin={onMomentumScrollBegin}
            onMomentumScrollEnd={onMomentumScrollEnd}
            onScrollBeginDrag={onScrollBeginDrag}
            onScrollEndDrag={onScrollEndDrag}
            openingIndex={openingIndex}
            originRect={originRect}
            overlayPhase={overlayPhase}
            progress={progress}
          />
        </OverlayClipHost>
      </GestureDetector>
    </View>
  );
});
Overlay.displayName = 'Overlay';

type OverlayContainerProps = {
  activeIndex: number | null;
  cities: readonly ZoomCity[];
  hiddenIndex: SharedValue<number>;
  initialOriginRect: Rect | null;
  onClosed: () => void;
  onIndexChange: (index: number) => void;
  originRect: SharedValue<Rect>;
};

export const OverlayContainer = memo(function OverlayContainerView({
  activeIndex,
  cities,
  hiddenIndex,
  initialOriginRect,
  onClosed,
  onIndexChange,
  originRect,
}: OverlayContainerProps) {
  if (activeIndex === null || initialOriginRect === null) return null;

  return (
    <Overlay
      cities={cities}
      hiddenIndex={hiddenIndex}
      initialIndex={activeIndex}
      initialOriginRect={initialOriginRect}
      onClosed={onClosed}
      onIndexChange={onIndexChange}
      originRect={originRect}
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
  maximumClipHost: {
    height: SCREEN_HEIGHT,
    left: 0,
    position: 'absolute',
    top: 0,
    width: SCREEN_WIDTH,
  },
  pager: { flex: 1 },
  placeholder: { height: SCREEN_HEIGHT, width: SCREEN_WIDTH },
});
