import { StyleSheet, Text, View } from 'react-native';

export function Header() {
  return (
    <View style={styles.container}>
      <Text style={styles.eyebrow}>FABRIC + REANIMATED</Text>
      <Text style={styles.title}>Ten clips. One shared clock.</Text>
      <Text style={styles.description}>
        Compare fixed-layout native clipping with animated layout under the same
        image-heavy workload.
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    alignItems: 'center',
    paddingHorizontal: 20,
    paddingTop: 20,
  },
  eyebrow: {
    color: '#66E3FF',
    fontSize: 11,
    fontWeight: '800',
    letterSpacing: 1.7,
  },
  title: {
    color: '#F7FAFF',
    fontSize: 26,
    fontWeight: '800',
    letterSpacing: -0.7,
    marginTop: 8,
    textAlign: 'center',
  },
  description: {
    color: '#9FB0C7',
    fontSize: 13,
    lineHeight: 19,
    marginTop: 7,
    maxWidth: 370,
    textAlign: 'center',
  },
});
