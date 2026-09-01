import { LegendList } from '@legendapp/list/react-native';
import type { ImageRef } from 'expo-image';
import { memo, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  BackHandler,
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
  resolveGalleryPresentationScalars,
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
): GalleryPresentation {
  'worklet';
  driver.ui.setScalars(...resolveGalleryPresentationScalars(presentation));
  return presentation;
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
  hiddenIndex: SharedValue<number>;
  initialOriginRect: Rect | null;
  onClosed: () => void;
  onIndexChange: (index: number) => void;
  openIndex: number | null;
  originIndex: SharedValue<number>;
  originRect: SharedValue<Rect>;
  thumbRef: ImageRef | null;
};

type GalleryOverlayContentProps = {
  hiddenIndex: SharedValue<number>;
  initialIndex: number;
  initialOriginRect: Rect;
  onClosed: () => void;
  onIndexChange: (index: number) => void;
  openingThumbRef: ImageRef | null;
  originIndex: SharedValue<number>;
  originRect: SharedValue<Rect>;
};

const GalleryOverlayContent = memo(function GalleryOverlayContentView({
  hiddenIndex,
  initialIndex,
  initialOriginRect,
  onClosed,
  onIndexChange,
  openingThumbRef,
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
  const currentIndex = useSharedValue(openingIndex);
  const currentRestFrame = useSharedValue(openingDestinationFrame);
  const dragTranslateX = useSharedValue(0);
  const dragTranslateY = useSharedValue(0);
  const closingIndex = useSharedValue(-1);
  const closeProgress = useSharedValue(0);
  const closeStartPresentation =
    useSharedValue<GalleryPresentation>(initialPresentation);
  const closeHasExplicitStart = useSharedValue(false);
  const closeStartBackdropOpacity = useSharedValue(0);
  const closeRequested = useSharedValue(false);
  const pagingActive = useSharedValue(false);
  const handoffStarted = useSharedValue(false);
  const gestureStartFrame = useSharedValue<GalleryFrame>(sourceFrame);
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
          // Let the tile's opacity update paint once under the landed overlay.
          requestAnimationFrame(() => scheduleOnRN(onClosed));
        }
      });
    },
    [hiddenIndex, onClosed, phase]
  );
  const driver = useSmoothClipDriver(initialPresentation, {
    onAnimationComplete: onNativeAnimationComplete,
  });

  const openPresentation = useMemo(
    () =>
      resolveGalleryPresentation(
        openingDestinationFrame,
        openingDestinationFrame,
        SCREEN_WIDTH,
        SCREEN_HEIGHT
      ),
    [openingDestinationFrame]
  );

  // One readiness signal starts the open: the opening page's thumb layer
  // reports its pixels applied (onDisplay). The overlay mounts into the
  // already-composited root surface with the grid tile still visible beneath
  // the pixel-identical seeded copy, so a frame of skew either way is an
  // invisible overlap — never a hole. The ref keeps the start once-only when
  // the thumb's borrowed-to-owned source switch re-fires onDisplay.
  const openStartedRef = useRef(false);
  const startOpen = useCallback(() => {
    if (openStartedRef.current) return;
    openStartedRef.current = true;
    handoffStarted.set(true);
    hiddenIndex.set(openingIndex);
    driver.react.animateTo(openPresentation, {
      ...NATIVE_TIMING,
      from: initialPresentation,
    });
    openingProgress.set(withTiming(1, TIMING_CONFIG));
  }, [
    driver,
    handoffStarted,
    hiddenIndex,
    initialPresentation,
    openPresentation,
    openingIndex,
    openingProgress,
  ]);

  // The pager's initialScrollIndex offset applies a few frames late (the
  // ScrollView clamps it until the list's content is sized), so the clip
  // would briefly show page 0's territory — a black hole — if it looked at
  // the pager during the open. Instead the flight renders a standalone copy
  // of the opening page above the pager: unconditional pixels from the first
  // commit, no scroll-state dependency. The pager stays invisible and
  // scroll-locked until the phase leaves OPENING, by which point its offset
  // has long settled and the swap is pixel-identical in one commit.
  const [openSettled, setOpenSettled] = useState(false);
  const markOpenSettled = useCallback(() => setOpenSettled(true), []);
  useAnimatedReaction(
    () => phase.get() !== GALLERY_PHASE_OPENING,
    (exited, wasExited) => {
      if (exited && !wasExited) scheduleOnRN(markOpenSettled);
    },
    [markOpenSettled, phase]
  );

  const startClose = useCallback(() => {
    'worklet';
    if (phase.get() === GALLERY_PHASE_CLOSING) return;

    const index = currentIndex.get();
    const destinationFrame = currentRestFrame.get();
    const wasOpening = phase.get() === GALLERY_PHASE_OPENING;
    const hasExplicitStart = closeHasExplicitStart.get();
    const startPresentation = hasExplicitStart
      ? closeStartPresentation.get()
      : resolveGalleryPresentation(
          frameFromPresentation(driver.ui.beginInteraction()),
          destinationFrame,
          SCREEN_WIDTH,
          SCREEN_HEIGHT
        );
    const startFrame = frameFromPresentation(startPresentation);

    cancelAnimation(openingProgress);
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
    driver.ui.animateTo(targetPresentation, {
      ...NATIVE_CLOSE_TIMING,
      from: startPresentation,
    });
    closeProgress.set(0);
    closeProgress.set(withTiming(1, CLOSE_TIMING_CONFIG));
  }, [
    closeHasExplicitStart,
    closeProgress,
    closeRequested,
    closeStartBackdropOpacity,
    closeStartPresentation,
    closingIndex,
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
          cancelAnimation(dragTranslateX);
          cancelAnimation(dragTranslateY);
          gestureStartFrame.set(visibleFrame);
          dragTranslateX.set(0);
          dragTranslateY.set(0);
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
        })
        .onEnd((event) => {
          gestureState.set({ ...gestureState.get(), activated: false });
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
          const releasePresentation = applyPresentationScalars(
            driver,
            presentation
          );

          if (event.translationY > 120 || event.velocityY > 600) {
            closeStartPresentation.set(releasePresentation);
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
              from: releasePresentation,
            });
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
      closeStartPresentation,
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
      cancelAnimation(dragTranslateX);
      cancelAnimation(dragTranslateY);
      phase.set(GALLERY_PHASE_OPEN);
      pagingActive.set(true);
      openingProgress.set(1);
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
    [driver, pagingActive]
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
        closeProgress={closeProgress}
        closingIndex={closingIndex}
        image={item}
        index={index}
      />
    ),
    [closeProgress, closingIndex]
  );
  const getFixedItemSize = useCallback(() => SCREEN_WIDTH, []);

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

  // Hardware back (Android) closes with the clip animation instead of popping
  // the screen beneath the overlay; swallow it even mid-close so a double
  // press can't escape. Mount-time registration puts this listener ahead of
  // the navigator's (LIFO).
  useEffect(() => {
    const subscription = BackHandler.addEventListener(
      'hardwareBackPress',
      () => {
        requestClose();
        return true;
      }
    );
    return () => subscription.remove();
  }, [requestClose]);

  // Whatever unmounts the overlay, never leave a grid tile hidden behind it.
  useEffect(() => () => hiddenIndex.set(-1), [hiddenIndex]);

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
          style={styles.clipHost}
          testID="gallery-smooth-clip-host"
        >
          <View style={styles.clipContent} testID="gallery-smooth-clip-content">
            <LegendList
              data={GALLERY_IMAGES as GalleryImage[]}
              drawDistance={SCREEN_WIDTH}
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
              scrollEnabled={openSettled}
              showsHorizontalScrollIndicator={false}
              style={[styles.pager, !openSettled && styles.pagerHidden]}
              testID="gallery-pager"
            />
            {!openSettled && (
              <View pointerEvents="none" style={styles.openingPageHolder}>
                <GalleryImagePage
                  closeProgress={closeProgress}
                  closingIndex={closingIndex}
                  image={openingImage}
                  index={openingIndex}
                  onThumbDisplay={startOpen}
                  openingThumbRef={openingThumbRef}
                />
              </View>
            )}
          </View>
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
  hiddenIndex,
  initialOriginRect,
  onClosed,
  onIndexChange,
  openIndex,
  originIndex,
  originRect,
  thumbRef,
}: GalleryOverlayProps) {
  if (openIndex === null || initialOriginRect === null) return null;

  return (
    <GalleryOverlayContent
      hiddenIndex={hiddenIndex}
      initialIndex={openIndex}
      initialOriginRect={initialOriginRect}
      onClosed={onClosed}
      onIndexChange={onIndexChange}
      openingThumbRef={thumbRef}
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
  pagerHidden: { opacity: 0 },
  openingPageHolder: { ...StyleSheet.absoluteFill },
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
