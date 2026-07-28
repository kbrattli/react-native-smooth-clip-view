import { StatusBar } from 'expo-status-bar';
import { useState } from 'react';
import { SafeAreaView, ScrollView, StyleSheet } from 'react-native';
import { Header } from './components/Header';
import { ImplementationSwitcher } from './components/ImplementationSwitcher';
import {
  StressTestScreen,
  type StressImplementation,
} from './components/StressTestScreen';

export default function App() {
  const [implementation, setImplementation] =
    useState<StressImplementation>('smooth-clip');

  return (
    <SafeAreaView style={styles.safeArea}>
      <StatusBar style="light" />
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
  safeArea: {
    flex: 1,
    backgroundColor: '#07111F',
  },
  scrollContent: {
    paddingBottom: 28,
  },
});
