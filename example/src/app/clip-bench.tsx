import { StyleSheet } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { ClipBench } from '../components/ClipBench';

export default function ClipBenchScreen() {
  return (
    <SafeAreaView edges={['bottom']} style={styles.safeArea}>
      <ClipBench />
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safeArea: { flex: 1, backgroundColor: '#07111F' },
});
