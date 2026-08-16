import {
  createContext,
  useCallback,
  useContext,
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
};

const SharedElementTransitionContext =
  createContext<SharedElementTransitionValue | null>(null);

/**
 * Shared state for a collection route and its transparent modal overlay. The
 * modal leaves the collection mounted, so registered item refs stay measurable
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
    originIndex.set(-1);
    setActiveIndex(null);
    setInitialOriginRect(null);
  }, [originIndex]);

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
      closeOverlay,
      hiddenIndex,
      initialOriginRect,
      measureItem,
      openItem,
      originIndex,
      originRect,
      registerItemRef,
      updateActiveIndex,
    }),
    [
      activeIndex,
      closeOverlay,
      hiddenIndex,
      initialOriginRect,
      measureItem,
      openItem,
      originIndex,
      originRect,
      registerItemRef,
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
