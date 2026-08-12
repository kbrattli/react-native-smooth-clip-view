import { useState } from 'react';
import { ScrollView, StyleSheet } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { DismissHarness } from '../components/DismissHarness';
import { Header } from '../components/Header';
import { ImplementationSwitcher } from '../components/ImplementationSwitcher';
import {
  StressTestScreen,
  type StressImplementation,
} from '../components/StressTestScreen';

export default function BenchmarkScreen() {
  const [implementation, setImplementation] =
    useState<StressImplementation>('smooth-clip');

  return (
    <SafeAreaView edges={['bottom']} style={styles.safeArea}>
      <DismissHarness />
      <ScrollView
        contentContainerStyle={styles.scrollContent}
        showsVerticalScrollIndicator={false}
        testID="stress-scroll-view"
      >
        <Header />
        <ImplementationSwitcher
          implementation={implementation}
          onChange={setImplementation}
        />
        <StressTestScreen
          key={implementation}
          implementation={implementation}
        />
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safeArea: { flex: 1, backgroundColor: '#07111F' },
  scrollContent: { paddingBottom: 28 },
});
