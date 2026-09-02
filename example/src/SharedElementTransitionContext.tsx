import type { ImageRef } from 'expo-image';
import {
  createContext,
  useCallback,
  useContext,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react';
import type { HostInstance } from 'react-native';
import {
  measure,
  useSharedValue,
  type AnimatedRef,
  type SharedValue,
} from 'react-native-reanimated';
import { scheduleOnUI } from 'react-native-worklets';
import type { Rect } from './zoomCities';

type ItemRef = AnimatedRef<HostInstance>;

export type GalleryOpenState = Readonly<{
  /** Tapped index; fixed for the whole overlay session. */
  openIndex: number;
  /** Tile rect at tap time; seeds the clip driver's first frame. */
  openRect: Rect;
  /** The tapped tile's live decoded thumbnail, borrowed for the first frame. */
  thumbRef: ImageRef | null;
  /** The pager's current rest index; drives the grid's follow-scroll. */
  activeIndex: number;
}>;

type SharedElementTransitionValue = {
  /** Index of the item currently hidden behind the overlay; -1 when none. */
  hiddenIndex: SharedValue<number>;
  /** Live rect of the item the overlay should land on. */
  originRect: SharedValue<Rect>;
  /** Index whose measurement currently occupies `originRect`. */
  originIndex: SharedValue<number>;
  /** Rect captured at open time; seeds the driver so native never flashes. */
  initialOriginRect: Rect | null;
  activeIndex: number | null;
  openItem: (index: number, rect: Rect) => void;
  updateActiveIndex: (index: number) => void;
  closeOverlay: () => void;
  /** Re-measure an item into `originRect` after the pager settles elsewhere. */
  measureItem: (itemId: string, index?: number) => void;
  registerItemRef: (itemId: string, ref: ItemRef | null) => void;
  /** Root-hosted gallery overlay session; null while the overlay is closed. */
  galleryState: GalleryOpenState | null;
  openGalleryItem: (
    index: number,
    rect: Rect,
    thumbRef: ImageRef | null
  ) => void;
  setGalleryActiveIndex: (index: number) => void;
  closeGallery: () => void;
};

const SharedElementTransitionContext =
  createContext<SharedElementTransitionValue | null>(null);

/**
 * Shared state for a collection screen and its fullscreen overlay. The zoom
 * demo hosts its overlay as a transparent modal route; the gallery hosts its
 * overlay as a root-surface sibling of the navigator. Either way the
 * collection stays mounted beneath, so registered item refs stay measurable
 * until the close animation finishes.
 */
export function SharedElementTransitionProvider({
  children,
}: {
  children: ReactNode;
}) {
  const hiddenIndex = useSharedValue(-1);
  const originRect = useSharedValue<Rect>({ x: 0, y: 0, w: 0, h: 0 });
  const originIndex = useSharedValue(-1);
  const [activeIndex, setActiveIndex] = useState<number | null>(null);
  const [initialOriginRect, setInitialOriginRect] = useState<Rect | null>(null);
  const refs = useRef<Map<string, ItemRef>>(new Map());

  const registerItemRef = useCallback((itemId: string, ref: ItemRef | null) => {
    if (ref) refs.current.set(itemId, ref);
    else refs.current.delete(itemId);
  }, []);

  const openItem = useCallback(
    (index: number, rect: Rect) => {
      originIndex.set(index);
      setActiveIndex(index);
      setInitialOriginRect(rect);
    },
    [originIndex]
  );

  const updateActiveIndex = useCallback((index: number) => {
    setActiveIndex(index);
  }, []);

  const closeOverlay = useCallback(() => {
    setActiveIndex(null);
    setInitialOriginRect(null);
  }, []);

  const [galleryState, setGalleryState] = useState<GalleryOpenState | null>(
    null
  );
  // Synchronous session guard: a second tap in the same JS turn (double-tap,
  // or a tap on a tile revealed mid-close) must no-op before any state lands.
  const gallerySessionRef = useRef(false);

  const openGalleryItem = useCallback(
    (index: number, rect: Rect, thumbRef: ImageRef | null) => {
      if (gallerySessionRef.current) return;
      gallerySessionRef.current = true;
      originIndex.set(index);
      setGalleryState({
        activeIndex: index,
        openIndex: index,
        openRect: rect,
        thumbRef,
      });
    },
    [originIndex]
  );

  const setGalleryActiveIndex = useCallback((index: number) => {
    setGalleryState((previous) =>
      previous ? { ...previous, activeIndex: index } : previous
    );
  }, []);

  const closeGallery = useCallback(() => {
    gallerySessionRef.current = false;
    setGalleryState(null);
  }, []);

  // Completion callbacks update React state only. Reset UI-runtime source
  // visibility from the resulting commit, outside the native event task and
  // before React Native paints the frame without an overlay.
  useLayoutEffect(() => {
    if (activeIndex !== null || galleryState !== null) return;
    hiddenIndex.set(-1);
    originIndex.set(-1);
  }, [activeIndex, galleryState, hiddenIndex, originIndex]);

  const measureItem = useCallback(
    (itemId: string, index?: number) => {
      const ref = refs.current.get(itemId);
      if (!ref) return;
      scheduleOnUI(
        (
          targetRef: ItemRef,
          targetOriginRect: SharedValue<Rect>,
          targetOriginIndex: SharedValue<number>,
          targetIndex: number | undefined
        ) => {
          'worklet';
          const measured = measure(targetRef);
          if (!measured) return;
          targetOriginRect.set({
            x: measured.pageX,
            y: measured.pageY,
            w: measured.width,
            h: measured.height,
          });
          if (targetIndex !== undefined) {
            targetOriginIndex.set(targetIndex);
          }
        },
        ref,
        originRect,
        originIndex,
        index
      );
    },
    [originIndex, originRect]
  );

  const value = useMemo(
    () => ({
      activeIndex,
      closeGallery,
      closeOverlay,
      galleryState,
      hiddenIndex,
      initialOriginRect,
      measureItem,
      openGalleryItem,
      openItem,
      originIndex,
      originRect,
      registerItemRef,
      setGalleryActiveIndex,
      updateActiveIndex,
    }),
    [
      activeIndex,
      closeGallery,
      closeOverlay,
      galleryState,
      hiddenIndex,
      initialOriginRect,
      measureItem,
      openGalleryItem,
      openItem,
      originIndex,
      originRect,
      registerItemRef,
      setGalleryActiveIndex,
      updateActiveIndex,
    ]
  );

  return (
    <SharedElementTransitionContext.Provider value={value}>
      {children}
    </SharedElementTransitionContext.Provider>
  );
}

export function useSharedElementTransition(): SharedElementTransitionValue {
  const value = useContext(SharedElementTransitionContext);
  if (!value) {
    throw new Error(
      'useSharedElementTransition must be used inside a SharedElementTransitionProvider'
    );
  }
  return value;
}
