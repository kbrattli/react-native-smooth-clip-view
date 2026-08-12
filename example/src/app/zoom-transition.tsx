import { useRouter } from 'expo-router';
import { useCallback } from 'react';
import { ScrollView, StyleSheet, Text } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { ZoomCardList } from '../components/ZoomCardList';
import { useZoomTransition } from '../ZoomTransitionContext';
import { ZOOM_CITIES, type Rect } from '../zoomCities';

export default function ZoomTransitionScreen() {
  const router = useRouter();
  const { hiddenIndex, openCard, originRect, registerCardRef } =
    useZoomTransition();

  // The card measured its own page rect on the UI thread; hand it to the
  // overlay route, which seeds the native clip with it so the first frame is
  // already the card and never a fullscreen flash.
  const onCardMeasured = useCallback(
    (payload: { index: number; rect: Rect }) => {
      openCard(payload.index, payload.rect);
      router.push('/zoom-overlay');
    },
    [openCard, router]
  );

  return (
    <SafeAreaView edges={['bottom']} style={styles.safeArea}>
      <ScrollView
        contentContainerStyle={styles.scrollContent}
        showsVerticalScrollIndicator={false}
        testID="zoom-scroll-view"
      >
        <Text style={styles.eyebrow}>TAP A CARD</Text>
        <Text style={styles.description}>
          The card zooms into a transparent modal route through a native clip
          window. Drag the page down to dismiss it back onto its card.
        </Text>
        <ZoomCardList
          cities={ZOOM_CITIES}
          hiddenIndex={hiddenIndex}
          onCardMeasured={onCardMeasured}
          onRegisterRef={registerCardRef}
          originRect={originRect}
        />
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safeArea: { flex: 1, backgroundColor: '#07111F' },
  scrollContent: { paddingBottom: 28, paddingTop: 16 },
  eyebrow: {
    color: '#66E3FF',
    fontSize: 11,
    fontWeight: '800',
    letterSpacing: 1.7,
    paddingHorizontal: 20,
  },
  description: {
    color: '#9FB0C7',
    fontSize: 13,
    lineHeight: 19,
    paddingHorizontal: 20,
    paddingTop: 6,
  },
});
