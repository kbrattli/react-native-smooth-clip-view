import { memo } from 'react';
import { StyleSheet, Text, View } from 'react-native';

type CompactScoreDisplayProps = {
  score: number;
};

/**
 * The card's score readout, rendered in TWO places: on the card itself, and in
 * the opened page's compact header. The page's copy is invisible except during
 * the close, where it cross-fades in so the score is already sitting in its
 * final position when the clip window lands back on the card.
 *
 * The reference app fetches this value; here it is static per city, since the
 * example is about the transition rather than the data.
 */
export const CompactScoreDisplay = memo(
  ({ score }: CompactScoreDisplayProps) => (
    <View style={styles.compactRow}>
      <Text allowFontScaling={false} style={styles.value}>
        {score}
      </Text>
      <Text allowFontScaling={false} style={styles.unit}>
        %
      </Text>
    </View>
  )
);
CompactScoreDisplay.displayName = 'CompactScoreDisplay';

const styles = StyleSheet.create({
  compactRow: { alignItems: 'flex-start', flexDirection: 'row' },
  value: {
    color: '#FFFFFF',
    fontSize: 24,
    fontWeight: '700',
    lineHeight: 32,
  },
  unit: {
    color: '#FFFFFF',
    fontSize: 14,
    fontWeight: '700',
    lineHeight: 18,
    marginLeft: 1,
    marginTop: 4,
    opacity: 0.8,
  },
});
