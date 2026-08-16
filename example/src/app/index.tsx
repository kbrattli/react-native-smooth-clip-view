import { ScrollView, StyleSheet, Text } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { RouteCard } from '../components/RouteCard';

const ROUTES = [
  { href: '/zoom-transition', title: 'Zoom transition' },
  { href: '/benchmark-screen', title: 'Stress benchmark' },
  { href: '/clip-bench', title: 'Clip bench' },
] as const;

export default function HomeScreen() {
  return (
    <SafeAreaView edges={['bottom']} style={styles.safeArea}>
      <ScrollView
        contentContainerStyle={styles.scrollContent}
        showsVerticalScrollIndicator={false}
        testID="home-scroll-view"
      >
        <Text style={styles.eyebrow}>EXAMPLES</Text>
        {ROUTES.map((route) => (
          <RouteCard key={route.href} {...route} />
        ))}
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safeArea: { flex: 1, backgroundColor: '#07111F' },
  scrollContent: { paddingBottom: 28, paddingHorizontal: 20, paddingTop: 16 },
  eyebrow: {
    color: '#66E3FF',
    fontSize: 11,
    fontWeight: '800',
    letterSpacing: 1.7,
  },
});
