import { useRouter } from 'expo-router';
import { useCallback, useEffect } from 'react';
import { StyleSheet, View } from 'react-native';
import { OverlayContainer } from '../components/ZoomOverlay';
import { useSharedElementTransition } from '../SharedElementTransitionContext';
import { ZOOM_CITIES } from '../zoomCities';

/**
 * The opened card, as its own route.
 *
 * Registered with `presentation: 'transparentModal'` and `animation: 'none'`
 * so the navigator contributes no motion of its own and leaves the card list
 * mounted and visible underneath — the entire transition is the native clip
 * window animating over it.
 */
export default function ZoomOverlayRoute() {
  const router = useRouter();
  const {
    activeIndex,
    closeOverlay,
    hiddenIndex,
    initialOriginRect,
    measureItem,
    originRect,
    updateActiveIndex,
  } = useSharedElementTransition();

  // Whatever unmounts this route, close the React-owned overlay session. The
  // provider resets UI-runtime source visibility from the resulting commit.
  useEffect(() => {
    return closeOverlay;
  }, [closeOverlay]);

  const onClosed = useCallback(() => {
    closeOverlay();
    router.back();
  }, [closeOverlay, router]);

  // The pager settled on a different city: re-measure that card so a close
  // lands on the card you paged to rather than the one you opened.
  const onIndexChange = useCallback(
    (index: number) => {
      const city = ZOOM_CITIES[index];
      if (!city) return;
      updateActiveIndex(index);
      measureItem(city.id);
    },
    [measureItem, updateActiveIndex]
  );

  return (
    <View pointerEvents="box-none" style={styles.root}>
      <OverlayContainer
        activeIndex={activeIndex}
        cities={ZOOM_CITIES}
        hiddenIndex={hiddenIndex}
        initialOriginRect={initialOriginRect}
        onClosed={onClosed}
        onIndexChange={onIndexChange}
        originRect={originRect}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  root: { backgroundColor: 'transparent', flex: 1 },
});
