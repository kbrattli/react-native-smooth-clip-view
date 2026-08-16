import { LegendList } from '@legendapp/list/react-native';
import { memo, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  Pressable,
  StyleSheet,
  Text,
  View,
  type NativeScrollEvent,
  type NativeSyntheticEvent,
} from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import Animated, {
  cancelAnimation,
  interpolate,
  useAnimatedReaction,
  useAnimatedStyle,
  useSharedValue,
  withTiming,
  type SharedValue,
} from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import {
  SmoothClipView,
  useSmoothClipDriver,
  type ClipAnimationResult,
  type SmoothClipDriver,
  type SmoothClipPresentation,
} from 'react-native-smooth-clip-view';
import { scheduleOnRN, scheduleOnUI } from 'react-native-worklets';
import {
  resolveAspectFitFrame,
  resolveDraggedGalleryFrame,
  resolveGalleryBackdropOpacity,
  resolveGalleryDismissProgress,
  resolveGalleryFrameProgress,
  resolveGalleryPresentation,
  type GalleryFrame,
  type GalleryPresentation,
} from '../galleryGeometry';
import {
  GALLERY_IMAGES,
  galleryImageKeyExtractor,
  type GalleryImage,
} from '../galleryImages';
import {
  CLOSE_TIMING_CONFIG,
  FAST_TIMING,
  NATIVE_CLOSE_TIMING,
  NATIVE_FAST_TIMING,
  NATIVE_TIMING,
  SCREEN_HEIGHT,
  SCREEN_WIDTH,
  TIMING_CONFIG,
} from '../overlayConstants';
import type { Rect } from '../zoomCities';
import GalleryImagePage from './GalleryImagePage';

const GALLERY_PHASE_OPENING = 0;
const GALLERY_PHASE_OPEN = 1;
const GALLERY_PHASE_CLOSING = 2;
const DISMISS_DISTANCE = SCREEN_HEIGHT * 0.5;
const MAX_DRAG_TRANSLATE_Y = SCREEN_HEIGHT;

type DismissGestureState = Readonly<{
  activated: boolean;
  startX: number;
  startY: number;
}>;

type OpeningImageReadiness = {
  displayed: boolean;
  hostLaidOut: boolean;
  laidOut: boolean;
};

const FULLSCREEN_FRAME: GalleryFrame = {
  x: 0,
  y: 0,
  width: SCREEN_WIDTH,
  height: SCREEN_HEIGHT,
};

function frameFromPresentation(
  presentation: SmoothClipPresentation
): GalleryFrame {
  'worklet';
  return {
    x: presentation.clip.x,
    y: presentation.clip.y,
    width: presentation.clip.width,
    height: presentation.clip.height,
  };
}

function applyPresentationScalars(
  driver: SmoothClipDriver,
  presentation: GalleryPresentation
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

function resolveGesturePresentation(
  startFrame: GalleryFrame,
  destinationFrame: GalleryFrame,
  translateX: number,
  translateY: number
) {
  'worklet';
  const dismissProgress = resolveGalleryDismissProgress(
    translateY,
    DISMISS_DISTANCE
  );
  const frame = resolveDraggedGalleryFrame(
    startFrame,
    translateX,
    translateY,
    dismissProgress
  );
  return {
    frame,
    presentation: resolveGalleryPresentation(
      frame,
      destinationFrame,
      SCREEN_WIDTH,
      SCREEN_HEIGHT
    ),
  };
}

function GalleryOverlayChrome({
  closeProgress,
  closeStartBackdropOpacity,
  closingIndex,
  dragTranslateY,
  openingProgress,
  requestClose,
}: {
  closeProgress: SharedValue<number>;
  closeStartBackdropOpacity: SharedValue<number>;
  closingIndex: SharedValue<number>;
  dragTranslateY: SharedValue<number>;
  openingProgress: SharedValue<number>;
  requestClose: () => void;
}) {
  const insets = useSafeAreaInsets();
  const animatedStyle = useAnimatedStyle(() => {
    if (closingIndex.get() >= 0) {
      return {
        opacity: closeStartBackdropOpacity.get() * (1 - closeProgress.get()),
      };
    }

    const dismissProgress = resolveGalleryDismissProgress(
      dragTranslateY.get(),
      DISMISS_DISTANCE
    );
    return {
      opacity:
        interpolate(openingProgress.get(), [0.72, 1], [0, 1], 'clamp') *
        (1 - dismissProgress),
    };
  });

  return (
    <Animated.View
      style={[styles.closeContainer, { top: insets.top + 8 }, animatedStyle]}
    >
      <Pressable
        accessibilityLabel="Close gallery"
        accessibilityRole="button"
        hitSlop={8}
        onPress={requestClose}
        style={({ pressed }) => [
          styles.closeButton,
          pressed && styles.closeButtonPressed,
        ]}
        testID="gallery-close-button"
      >
        <Text allowFontScaling={false} style={styles.closeIcon}>
          X
        </Text>
      </Pressable>
    </Animated.View>
  );
}

type GalleryOverlayProps = {
  activeIndex: number | null;
  hiddenIndex: SharedValue<number>;
  initialOriginRect: Rect | null;
  onClosed: () => void;
  onIndexChange: (index: number) => void;
  originIndex: SharedValue<number>;
  originRect: SharedValue<Rect>;
};

type GalleryOverlayContentProps = {
  hiddenIndex: SharedValue<number>;
  initialIndex: number;
  initialOriginRect: Rect;
  onClosed: () => void;
  onIndexChange: (index: number) => void;
  originIndex: SharedValue<number>;
  originRect: SharedValue<Rect>;
};

const GalleryOverlayContent = memo(function GalleryOverlayContentView({
  hiddenIndex,
  initialIndex,
  initialOriginRect,
  onClosed,
  onIndexChange,
  originIndex,
  originRect,
}: GalleryOverlayContentProps) {
  const safeInitialIndex = Math.min(
    Math.max(initialIndex, 0),
    GALLERY_IMAGES.length - 1
  );
  const [openingIndex] = useState(safeInitialIndex);
  const openingImage = GALLERY_IMAGES[openingIndex]!;
  const sourceFrame = useMemo<GalleryFrame>(
    () => ({
      x: initialOriginRect.x,
      y: initialOriginRect.y,
      width: initialOriginRect.w,
      height: initialOriginRect.h,
    }),
    [initialOriginRect]
  );
  const openingDestinationFrame = useMemo(
    () =>
      resolveAspectFitFrame(
        SCREEN_WIDTH,
        SCREEN_HEIGHT,
        openingImage.width,
        openingImage.height
      ),
    [openingImage.height, openingImage.width]
  );
  const initialPresentation = useMemo(
    () =>
      resolveGalleryPresentation(
        sourceFrame,
        openingDestinationFrame,
        SCREEN_WIDTH,
        SCREEN_HEIGHT
      ),
    [openingDestinationFrame, sourceFrame]
  );

  const phase = useSharedValue(GALLERY_PHASE_OPENING);
  const openingProgress = useSharedValue(0);
  const contentScale = useSharedValue(initialPresentation.contentScale);
  const currentIndex = useSharedValue(openingIndex);
  const currentRestFrame = useSharedValue(openingDestinationFrame);
  const dragTranslateX = useSharedValue(0);
  const dragTranslateY = useSharedValue(0);
  const closingIndex = useSharedValue(-1);
  const closeProgress = useSharedValue(0);
  const closeStartFrame = useSharedValue<GalleryFrame>(sourceFrame);
  const closeHasExplicitStart = useSharedValue(false);
  const closeStartBackdropOpacity = useSharedValue(0);
  const closeRequested = useSharedValue(false);
  const pagingActive = useSharedValue(false);
  const handoffStarted = useSharedValue(false);
  const gestureStartFrame = useSharedValue<GalleryFrame>(sourceFrame);
  const [openingImageReadiness, setOpeningImageReadiness] =
    useState<OpeningImageReadiness>({
      displayed: false,
      hostLaidOut: false,
      laidOut: false,
    });
  const openingStartedRef = useRef(false);
  const gestureState = useSharedValue<DismissGestureState>({
    activated: false,
    startX: 0,
    startY: 0,
  });

  const onNativeAnimationComplete = useCallback(
    (result: ClipAnimationResult) => {
      if (!result.finished) return;

      scheduleOnUI(() => {
        'worklet';
        if (phase.get() === GALLERY_PHASE_OPENING) {
          phase.set(GALLERY_PHASE_OPEN);
        } else if (phase.get() === GALLERY_PHASE_CLOSING) {
          hiddenIndex.set(-1);
          scheduleOnRN(onClosed);
        }
      });
    },
    [hiddenIndex, onClosed, phase]
  );
  const driver = useSmoothClipDriver(initialPresentation, {
    onAnimationComplete: onNativeAnimationComplete,
  });

  useEffect(() => {
    if (
      openingStartedRef.current ||
      !openingImageReadiness.displayed ||
      !openingImageReadiness.hostLaidOut ||
      !openingImageReadiness.laidOut
    ) {
      return;
    }
    openingStartedRef.current = true;
    const openPresentation = resolveGalleryPresentation(
      openingDestinationFrame,
      openingDestinationFrame,
      SCREEN_WIDTH,
      SCREEN_HEIGHT
    );

    scheduleOnUI(() => {
      'worklet';
      if (phase.get() !== GALLERY_PHASE_OPENING) return;
      handoffStarted.set(true);
      hiddenIndex.set(openingIndex);
      driver.ui.animateTo(openPresentation, {
        ...NATIVE_TIMING,
        from: initialPresentation,
      });
      contentScale.set(withTiming(1, TIMING_CONFIG));
      openingProgress.set(withTiming(1, TIMING_CONFIG));
    });
  }, [
    contentScale,
    driver,
    handoffStarted,
    hiddenIndex,
    initialPresentation,
    openingDestinationFrame,
    openingImageReadiness.displayed,
    openingImageReadiness.hostLaidOut,
    openingImageReadiness.laidOut,
    openingIndex,
    openingProgress,
    phase,
  ]);

  const onOpeningImageDisplay = useCallback(
    (imageId: string, index: number) => {
      if (index !== openingIndex || imageId !== openingImage.id) return;
      setOpeningImageReadiness((readiness) =>
        readiness.displayed ? readiness : { ...readiness, displayed: true }
      );
    },
    [openingImage.id, openingIndex]
  );

  const onOpeningImageLayout = useCallback(
    (imageId: string, index: number) => {
      if (index !== openingIndex || imageId !== openingImage.id) return;
      setOpeningImageReadiness((readiness) =>
        readiness.laidOut ? readiness : { ...readiness, laidOut: true }
      );
    },
    [openingImage.id, openingIndex]
  );

  const onClipHostLayout = useCallback(() => {
    setOpeningImageReadiness((readiness) =>
      readiness.hostLaidOut ? readiness : { ...readiness, hostLaidOut: true }
    );
  }, []);

  const startClose = useCallback(() => {
    'worklet';
    if (phase.get() === GALLERY_PHASE_CLOSING) return;

    const index = currentIndex.get();
    const destinationFrame = currentRestFrame.get();
    const wasOpening = phase.get() === GALLERY_PHASE_OPENING;
    const startFrame = closeHasExplicitStart.get()
      ? closeStartFrame.get()
      : frameFromPresentation(driver.ui.beginInteraction());

    cancelAnimation(openingProgress);
    cancelAnimation(contentScale);
    cancelAnimation(dragTranslateX);
    cancelAnimation(dragTranslateY);

    if (wasOpening) {
      openingProgress.set(
        resolveGalleryFrameProgress(sourceFrame, destinationFrame, startFrame)
      );
    }

    const dismissProgress = resolveGalleryDismissProgress(
      dragTranslateY.get(),
      DISMISS_DISTANCE
    );
    const startPresentation = resolveGalleryPresentation(
      startFrame,
      destinationFrame,
      SCREEN_WIDTH,
      SCREEN_HEIGHT
    );
    const target = originRect.get();
    const targetFrame: GalleryFrame = {
      x: target.x,
      y: target.y,
      width: target.w,
      height: target.h,
    };
    const targetPresentation = resolveGalleryPresentation(
      targetFrame,
      destinationFrame,
      SCREEN_WIDTH,
      SCREEN_HEIGHT
    );

    phase.set(GALLERY_PHASE_CLOSING);
    closeRequested.set(false);
    closeHasExplicitStart.set(false);
    closingIndex.set(index);
    closeStartBackdropOpacity.set(
      resolveGalleryBackdropOpacity(openingProgress.get(), dismissProgress)
    );
    contentScale.set(startPresentation.contentScale);
    driver.ui.animateTo(targetPresentation, {
      ...NATIVE_CLOSE_TIMING,
      from: startPresentation,
    });
    contentScale.set(
      withTiming(targetPresentation.contentScale, CLOSE_TIMING_CONFIG)
    );
    closeProgress.set(0);
    closeProgress.set(withTiming(1, CLOSE_TIMING_CONFIG));
  }, [
    closeHasExplicitStart,
    closeProgress,
    closeRequested,
    closeStartBackdropOpacity,
    closeStartFrame,
    closingIndex,
    contentScale,
    currentIndex,
    currentRestFrame,
    dragTranslateX,
    dragTranslateY,
    driver,
    openingProgress,
    originRect,
    phase,
    sourceFrame,
  ]);

  const requestCloseOnUI = useCallback(() => {
    'worklet';
    if (phase.get() === GALLERY_PHASE_CLOSING) return;
    closeHasExplicitStart.set(false);
    closeRequested.set(true);
  }, [closeHasExplicitStart, closeRequested, phase]);

  useAnimatedReaction(
    () =>
      closeRequested.get() &&
      !pagingActive.get() &&
      originIndex.get() === currentIndex.get(),
    (ready, wasReady) => {
      if (ready && !wasReady) startClose();
    },
    [closeRequested, currentIndex, originIndex, pagingActive, startClose]
  );

  const dismissGesture = useMemo(
    () =>
      Gesture.Pan()
        .manualActivation(true)
        .onTouchesDown((event, manager) => {
          if (event.numberOfTouches !== 1) {
            manager.fail();
            return;
          }
          const touch = event.allTouches[0]!;
          gestureState.set({
            activated: false,
            startX: touch.absoluteX,
            startY: touch.absoluteY,
          });
        })
        .onTouchesMove((event, manager) => {
          if (
            !handoffStarted.get() ||
            phase.get() === GALLERY_PHASE_CLOSING ||
            pagingActive.get()
          ) {
            manager.fail();
            return;
          }
          const state = gestureState.get();
          if (state.activated) return;
          if (event.numberOfTouches !== 1) {
            manager.fail();
            return;
          }

          const touch = event.allTouches[0]!;
          const deltaX = touch.absoluteX - state.startX;
          const deltaY = touch.absoluteY - state.startY;

          if (Math.abs(deltaX) > 15 || deltaY < 0) {
            manager.fail();
          } else if (deltaY >= 5) {
            gestureState.set({ ...state, activated: true });
            manager.activate();
          } else if (Math.abs(deltaX) > 3) {
            manager.fail();
          }
        })
        .onStart(() => {
          const visibleFrame = frameFromPresentation(
            driver.ui.beginInteraction()
          );
          const destinationFrame = currentRestFrame.get();

          cancelAnimation(openingProgress);
          cancelAnimation(contentScale);
          cancelAnimation(dragTranslateX);
          cancelAnimation(dragTranslateY);
          gestureStartFrame.set(visibleFrame);
          dragTranslateX.set(0);
          dragTranslateY.set(0);
          contentScale.set(
            resolveGalleryPresentation(
              visibleFrame,
              destinationFrame,
              SCREEN_WIDTH,
              SCREEN_HEIGHT
            ).contentScale
          );

          if (phase.get() === GALLERY_PHASE_OPENING) {
            openingProgress.set(
              resolveGalleryFrameProgress(
                sourceFrame,
                destinationFrame,
                visibleFrame
              )
            );
            phase.set(GALLERY_PHASE_OPEN);
          }
        })
        .onUpdate((event) => {
          const translateX = event.translationX * 0.7;
          const translateY = Math.min(
            MAX_DRAG_TRANSLATE_Y,
            Math.max(0, event.translationY)
          );
          const { presentation } = resolveGesturePresentation(
            gestureStartFrame.get(),
            currentRestFrame.get(),
            translateX,
            translateY
          );

          dragTranslateX.set(translateX);
          dragTranslateY.set(translateY);
          applyPresentationScalars(driver, presentation);
          contentScale.set(presentation.contentScale);
        })
        .onEnd((event) => {
          gestureState.set({ ...gestureState.get(), activated: false });
          const translateX = event.translationX * 0.7;
          const translateY = Math.min(
            MAX_DRAG_TRANSLATE_Y,
            Math.max(0, event.translationY)
          );
          const { frame, presentation } = resolveGesturePresentation(
            gestureStartFrame.get(),
            currentRestFrame.get(),
            translateX,
            translateY
          );

          dragTranslateX.set(translateX);
          dragTranslateY.set(translateY);
          applyPresentationScalars(driver, presentation);
          contentScale.set(presentation.contentScale);

          if (event.translationY > 120 || event.velocityY > 600) {
            closeStartFrame.set(frame);
            closeHasExplicitStart.set(true);
            closeRequested.set(true);
          } else {
            const destinationFrame = currentRestFrame.get();
            const restPresentation = resolveGalleryPresentation(
              destinationFrame,
              destinationFrame,
              SCREEN_WIDTH,
              SCREEN_HEIGHT
            );
            driver.ui.animateTo(restPresentation, {
              ...NATIVE_FAST_TIMING,
              from: presentation,
            });
            contentScale.set(withTiming(1, FAST_TIMING));
            openingProgress.set(withTiming(1, FAST_TIMING));
            dragTranslateX.set(withTiming(0, FAST_TIMING));
            dragTranslateY.set(withTiming(0, FAST_TIMING));
          }
        })
        .onFinalize(() => {
          gestureState.set({ ...gestureState.get(), activated: false });
        }),
    [
      closeHasExplicitStart,
      closeRequested,
      closeStartFrame,
      contentScale,
      currentRestFrame,
      dragTranslateX,
      dragTranslateY,
      driver,
      gestureStartFrame,
      gestureState,
      handoffStarted,
      openingProgress,
      pagingActive,
      phase,
      sourceFrame,
    ]
  );

  const lastIndexRef = useRef(openingIndex);
  const commitIndexIfChanged = useCallback(
    (index: number) => {
      const clampedIndex = Math.min(
        Math.max(index, 0),
        GALLERY_IMAGES.length - 1
      );
      const image = GALLERY_IMAGES[clampedIndex]!;
      const restFrame = resolveAspectFitFrame(
        SCREEN_WIDTH,
        SCREEN_HEIGHT,
        image.width,
        image.height
      );

      currentIndex.set(clampedIndex);
      currentRestFrame.set(restFrame);
      if (clampedIndex !== lastIndexRef.current) {
        lastIndexRef.current = clampedIndex;
        hiddenIndex.set(clampedIndex);
        onIndexChange(clampedIndex);
      }
      return { restFrame };
    },
    [currentIndex, currentRestFrame, hiddenIndex, onIndexChange]
  );

  const beginPaging = useCallback(() => {
    scheduleOnUI(() => {
      'worklet';
      if (phase.get() === GALLERY_PHASE_CLOSING) return;

      driver.ui.beginInteraction();
      cancelAnimation(openingProgress);
      cancelAnimation(contentScale);
      cancelAnimation(dragTranslateX);
      cancelAnimation(dragTranslateY);
      phase.set(GALLERY_PHASE_OPEN);
      pagingActive.set(true);
      openingProgress.set(1);
      contentScale.set(1);
      dragTranslateX.set(0);
      dragTranslateY.set(0);
      applyPresentationScalars(
        driver,
        resolveGalleryPresentation(
          FULLSCREEN_FRAME,
          FULLSCREEN_FRAME,
          SCREEN_WIDTH,
          SCREEN_HEIGHT
        )
      );
    });
  }, [
    contentScale,
    dragTranslateX,
    dragTranslateY,
    driver,
    openingProgress,
    pagingActive,
    phase,
  ]);

  const finishPaging = useCallback(
    (restFrame: GalleryFrame) => {
      scheduleOnUI(() => {
        'worklet';
        contentScale.set(1);
        applyPresentationScalars(
          driver,
          resolveGalleryPresentation(
            restFrame,
            restFrame,
            SCREEN_WIDTH,
            SCREEN_HEIGHT
          )
        );
        pagingActive.set(false);
      });
    },
    [contentScale, driver, pagingActive]
  );

  const momentumStartedRef = useRef(false);
  const onScrollBeginDrag = useCallback(() => {
    momentumStartedRef.current = false;
    beginPaging();
  }, [beginPaging]);
  const onMomentumScrollBegin = useCallback(() => {
    momentumStartedRef.current = true;
    pagingActive.set(true);
  }, [pagingActive]);
  const onScrollEndDrag = useCallback(
    (event: NativeSyntheticEvent<NativeScrollEvent>) => {
      const targetX =
        event.nativeEvent.targetContentOffset?.x ??
        event.nativeEvent.contentOffset.x;
      const { restFrame } = commitIndexIfChanged(
        Math.round(targetX / SCREEN_WIDTH)
      );
      requestAnimationFrame(() => {
        if (!momentumStartedRef.current) finishPaging(restFrame);
      });
    },
    [commitIndexIfChanged, finishPaging]
  );
  const onMomentumScrollEnd = useCallback(
    (event: NativeSyntheticEvent<NativeScrollEvent>) => {
      momentumStartedRef.current = false;
      const { restFrame } = commitIndexIfChanged(
        Math.round(event.nativeEvent.contentOffset.x / SCREEN_WIDTH)
      );
      finishPaging(restFrame);
    },
    [commitIndexIfChanged, finishPaging]
  );

  const renderItem = useCallback(
    ({ item, index }: { item: GalleryImage; index: number }) => (
      <GalleryImagePage
        image={item}
        index={index}
        openingIndex={openingIndex}
        onOpeningImageDisplay={onOpeningImageDisplay}
        onOpeningImageLayout={onOpeningImageLayout}
      />
    ),
    [onOpeningImageDisplay, onOpeningImageLayout, openingIndex]
  );
  const getFixedItemSize = useCallback(() => SCREEN_WIDTH, []);

  const contentStyle = useAnimatedStyle(() => ({
    transform: [{ scale: contentScale.get() }],
  }));

  const backdropStyle = useAnimatedStyle(() => {
    if (closingIndex.get() >= 0) {
      return {
        opacity: closeStartBackdropOpacity.get() * (1 - closeProgress.get()),
      };
    }
    return {
      opacity: resolveGalleryBackdropOpacity(
        openingProgress.get(),
        resolveGalleryDismissProgress(dragTranslateY.get(), DISMISS_DISTANCE)
      ),
    };
  });

  const requestClose = useCallback(() => {
    scheduleOnUI(requestCloseOnUI);
  }, [requestCloseOnUI]);

  return (
    <View pointerEvents="box-none" style={styles.root}>
      <Animated.View
        pointerEvents="none"
        style={[styles.backdrop, backdropStyle]}
        testID="gallery-backdrop"
      />
      <GestureDetector gesture={dismissGesture}>
        <SmoothClipView
          driver={driver}
          onLayout={onClipHostLayout}
          style={styles.clipHost}
          testID="gallery-smooth-clip-host"
        >
          <Animated.View
            style={[styles.clipContent, contentStyle]}
            testID="gallery-smooth-clip-content"
          >
            <LegendList
              data={GALLERY_IMAGES as GalleryImage[]}
              drawDistance={SCREEN_WIDTH * 1.5}
              estimatedItemSize={SCREEN_WIDTH}
              estimatedListSize={{
                height: SCREEN_HEIGHT,
                width: SCREEN_WIDTH,
              }}
              getFixedItemSize={getFixedItemSize}
              horizontal
              initialScrollIndex={openingIndex}
              keyExtractor={galleryImageKeyExtractor}
              onMomentumScrollBegin={onMomentumScrollBegin}
              onMomentumScrollEnd={onMomentumScrollEnd}
              onScrollBeginDrag={onScrollBeginDrag}
              onScrollEndDrag={onScrollEndDrag}
              pagingEnabled
              recycleItems
              renderItem={renderItem}
              scrollEnabled={
                openingImageReadiness.displayed && openingImageReadiness.laidOut
              }
              showsHorizontalScrollIndicator={false}
              style={styles.pager}
              testID="gallery-pager"
            />
          </Animated.View>
        </SmoothClipView>
      </GestureDetector>
      <GalleryOverlayChrome
        closeProgress={closeProgress}
        closeStartBackdropOpacity={closeStartBackdropOpacity}
        closingIndex={closingIndex}
        dragTranslateY={dragTranslateY}
        openingProgress={openingProgress}
        requestClose={requestClose}
      />
    </View>
  );
});
GalleryOverlayContent.displayName = 'GalleryOverlayContent';

export const GalleryOverlay = memo(function GalleryOverlayView({
  activeIndex,
  hiddenIndex,
  initialOriginRect,
  onClosed,
  onIndexChange,
  originIndex,
  originRect,
}: GalleryOverlayProps) {
  if (activeIndex === null || initialOriginRect === null) return null;

  return (
    <GalleryOverlayContent
      hiddenIndex={hiddenIndex}
      initialIndex={activeIndex}
      initialOriginRect={initialOriginRect}
      onClosed={onClosed}
      onIndexChange={onIndexChange}
      originIndex={originIndex}
      originRect={originRect}
    />
  );
});
GalleryOverlay.displayName = 'GalleryOverlay';

const styles = StyleSheet.create({
  root: {
    height: SCREEN_HEIGHT,
    left: 0,
    position: 'absolute',
    top: 0,
    width: SCREEN_WIDTH,
    zIndex: 999,
  },
  backdrop: {
    ...StyleSheet.absoluteFill,
    backgroundColor: '#000000',
  },
  clipHost: {
    height: SCREEN_HEIGHT,
    width: SCREEN_WIDTH,
  },
  clipContent: {
    height: SCREEN_HEIGHT,
    width: SCREEN_WIDTH,
  },
  pager: { backgroundColor: 'transparent', flex: 1 },
  closeContainer: {
    position: 'absolute',
    right: 12,
    zIndex: 20,
  },
  closeButton: {
    alignItems: 'center',
    backgroundColor: 'rgba(18, 18, 18, 0.72)',
    borderRadius: 22,
    height: 44,
    justifyContent: 'center',
    width: 44,
  },
  closeButtonPressed: { backgroundColor: 'rgba(48, 48, 48, 0.82)' },
  closeIcon: {
    color: '#FFFFFF',
    fontSize: 17,
    fontWeight: '700',
    lineHeight: 20,
  },
});
