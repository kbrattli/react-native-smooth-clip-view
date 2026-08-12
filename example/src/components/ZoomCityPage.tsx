import { memo } from 'react';
import { StyleSheet, Text } from 'react-native';
import Animated, {
  interpolate,
  type SharedValue,
  useAnimatedStyle,
} from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import {
  CARD_HEIGHT,
  CARD_PADDING,
  EXPANDED_HEADER_HEIGHT,
  EXPANDED_HEADER_PADDING_TOP,
  OVERLAY_PHASE_CLOSING,
  SCREEN_HEIGHT,
  SCREEN_WIDTH,
  type OverlayPhase,
} from '../overlayConstants';
import type { Rect, ZoomCity } from '../zoomCities';
import { CompactScoreDisplay } from './CompactScoreDisplay';

type ZoomCityPageProps = {
  city: ZoomCity;
  originRect: SharedValue<Rect>;
  overlayPhase: SharedValue<OverlayPhase>;
  progress: SharedValue<number>;
};

/**
 * The opened page. Its body is deliberately empty — the only content is the
 * pair of headers that carry the transition:
 *
 * - the EXPANDED header, which fades in over the last 30% of the open, and
 * - the COMPACT header, a pixel-replica of the card's content row that is
 *   invisible except during the close.
 */
const ZoomCityPage = memo(function ZoomCityPageView({
  city,
  originRect,
  overlayPhase,
  progress,
}: ZoomCityPageProps) {
  const insets = useSafeAreaInsets();

  // Only visible during the close: opacity = closing x (1 - progress), so it
  // ramps 0 -> 1 as the window shrinks back onto the card.
  const compactHeaderStyle = useAnimatedStyle(() => {
    const closing = overlayPhase.get() === OVERLAY_PHASE_CLOSING ? 1 : 0;
    return {
      opacity: closing * interpolate(progress.get(), [0, 1], [1, 0], 'clamp'),
    };
  });

  // The page is full-width but the card is inset on both sides, so push the
  // score inward by the width difference to land it exactly on the card's own.
  const compactScoreOffsetStyle = useAnimatedStyle(() => ({
    marginRight: SCREEN_WIDTH - originRect.get().w,
  }));

  const expandedHeaderStyle = useAnimatedStyle(() => {
    const currentProgress = progress.get();
    return {
      opacity: interpolate(currentProgress, [0.7, 1], [0, 1], 'clamp'),
      transform: [
        { translateY: interpolate(currentProgress, [0, 1], [-50, 0]) },
      ],
    };
  });

  return (
    <Animated.View
      style={[styles.page, { backgroundColor: city.color }]}
      testID={`zoom-page-${city.id}`}
    >
      <Animated.View style={[styles.compactHeader, compactHeaderStyle]}>
        <Text allowFontScaling={false} style={styles.compactTitle}>
          {city.title}
        </Text>
        <Animated.View style={compactScoreOffsetStyle}>
          <CompactScoreDisplay score={city.score} />
        </Animated.View>
      </Animated.View>

      <Animated.View
        style={[
          styles.expandedHeader,
          { paddingTop: insets.top + EXPANDED_HEADER_PADDING_TOP },
          expandedHeaderStyle,
        ]}
      >
        <Text allowFontScaling={false} style={styles.expandedTitle}>
          {city.title}
        </Text>
      </Animated.View>
    </Animated.View>
  );
});

ZoomCityPage.displayName = 'ZoomCityPage';

export default ZoomCityPage;

const styles = StyleSheet.create({
  page: { height: SCREEN_HEIGHT, width: SCREEN_WIDTH },
  compactHeader: {
    alignItems: 'center',
    flexDirection: 'row',
    height: CARD_HEIGHT,
    justifyContent: 'space-between',
    left: 0,
    overflow: 'visible',
    paddingHorizontal: CARD_PADDING,
    position: 'absolute',
    right: 0,
    top: 0,
    zIndex: 5,
  },
  compactTitle: {
    color: '#FFFFFF',
    fontSize: 24,
    fontWeight: '700',
    lineHeight: 32,
  },
  expandedHeader: {
    alignItems: 'center',
    height: EXPANDED_HEADER_HEIGHT,
    justifyContent: 'center',
    left: 0,
    overflow: 'visible',
    position: 'absolute',
    right: 0,
    top: 0,
    zIndex: 10,
  },
  expandedTitle: {
    color: '#FFFFFF',
    fontSize: 34,
    fontWeight: '800',
    lineHeight: 41,
  },
});
