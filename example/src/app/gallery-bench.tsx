import { ScrollView, StyleSheet, Text } from 'react-native';
import { RouteCard } from '../components/RouteCard';

/**
 * The gallery mount-time bench (docs/gallery-mount-time.md): the same photo
 * grid, opened to a detail route by seven transition variants.
 */
const VARIANTS = [
  { href: '/gallery-flight', title: 'SmoothClipView flight, no teleport' },
  {
    href: '/gallery-flight-teleport',
    title: 'SmoothClipView flight, with teleport',
  },
  { href: '/gallery-set', title: 'Reanimated shared transition, no teleport' },
  {
    href: '/gallery-set-teleport',
    // Not measured: the photo is hidden for the whole run (docs).
    title: 'Reanimated SET + teleport (broken, not measured)',
  },
  { href: '/gallery-transitions', title: 'screen-transitions, no teleport' },
  {
    href: '/gallery-transitions-teleport',
    title: 'screen-transitions, with teleport',
  },
  { href: '/gallery-choreography', title: 'screen-choreography (teleport)' },
] as const;

export default function GalleryBenchHome() {
  return (
    <ScrollView
      contentContainerStyle={styles.content}
      style={styles.screen}
      testID="gallery-bench-home"
    >
      <Text style={styles.eyebrow}>GALLERY VARIANTS</Text>
      {VARIANTS.map((variant) => (
        <RouteCard key={variant.href} {...variant} />
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: '#07111F' },
  content: { paddingBottom: 28, paddingHorizontal: 20, paddingTop: 16 },
  eyebrow: {
    color: '#66E3FF',
    fontSize: 11,
    fontWeight: '800',
    letterSpacing: 1.7,
  },
});
