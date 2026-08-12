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

type CardRef = AnimatedRef<HostInstance>;

type ZoomTransitionValue = {
  /** Index of the card currently hidden behind the overlay; -1 when none. */
  hiddenIndex: SharedValue<number>;
  /** Live rect of the card the overlay should land on. Re-measured on paging. */
  originRect: SharedValue<Rect>;
  /** Rect captured at open time; seeds the driver so native never flashes. */
  initialOriginRect: Rect | null;
  activeIndex: number | null;
  openCard: (index: number, rect: Rect) => void;
  closeOverlay: () => void;
  /** Re-measure a card into `originRect` after the pager settles elsewhere. */
  measureCard: (cityId: string) => void;
  registerCardRef: (cityId: string, ref: CardRef | null) => void;
};

const ZoomTransitionContext = createContext<ZoomTransitionValue | null>(null);

/**
 * Shared state for the two halves of the zoom transition, which live in
 * separate routes: the card list and the `transparentModal` overlay. The modal
 * keeps the list mounted underneath, so the card refs registered here stay
 * measurable for the whole time the overlay is open.
 */
export function ZoomTransitionProvider({ children }: { children: ReactNode }) {
  const hiddenIndex = useSharedValue(-1);
  const originRect = useSharedValue<Rect>({ x: 0, y: 0, w: 0, h: 0 });
  const [activeIndex, setActiveIndex] = useState<number | null>(null);
  const [initialOriginRect, setInitialOriginRect] = useState<Rect | null>(null);
  const refs = useRef<Map<string, CardRef>>(new Map());

  const registerCardRef = useCallback((cityId: string, ref: CardRef | null) => {
    if (ref) refs.current.set(cityId, ref);
    else refs.current.delete(cityId);
  }, []);

  const openCard = useCallback((index: number, rect: Rect) => {
    setActiveIndex(index);
    setInitialOriginRect(rect);
  }, []);

  const closeOverlay = useCallback(() => {
    setActiveIndex(null);
    setInitialOriginRect(null);
  }, []);

  const measureCard = useCallback(
    (cityId: string) => {
      const ref = refs.current.get(cityId);
      if (!ref) return;
      scheduleOnUI(
        (targetRef: CardRef, targetOriginRect: SharedValue<Rect>) => {
          'worklet';
          const measured = measure(targetRef);
          if (!measured) return;
          targetOriginRect.set({
            x: measured.pageX,
            y: measured.pageY,
            w: measured.width,
            h: measured.height,
          });
        },
        ref,
        originRect
      );
    },
    [originRect]
  );

  const value = useMemo(
    () => ({
      activeIndex,
      closeOverlay,
      hiddenIndex,
      initialOriginRect,
      measureCard,
      openCard,
      originRect,
      registerCardRef,
    }),
    [
      activeIndex,
      closeOverlay,
      hiddenIndex,
      initialOriginRect,
      measureCard,
      openCard,
      originRect,
      registerCardRef,
    ]
  );

  return (
    <ZoomTransitionContext.Provider value={value}>
      {children}
    </ZoomTransitionContext.Provider>
  );
}

export function useZoomTransition(): ZoomTransitionValue {
  const value = useContext(ZoomTransitionContext);
  if (!value) {
    throw new Error(
      'useZoomTransition must be used inside a ZoomTransitionProvider'
    );
  }
  return value;
}
