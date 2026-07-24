import { StyleSheet, Text } from 'react-native';

export function Header() {
  return (
    <>
      <Text style={styles.eyebrow}>FABRIC + REANIMATED</Text>
      <Text style={styles.title}>Smooth clip, fixed layout.</Text>
      <Text style={styles.description}>
        Animate width and height without expensive layout calculations while
        preserving a smooth border radius.
      </Text>
    </>
  );
}

const styles = StyleSheet.create({
  eyebrow: {
    color: '#66E3FF',
    fontSize: 12,
    fontWeight: '800',
    letterSpacing: 1.8,
  },
  title: {
    color: '#F7FAFF',
    fontSize: 30,
    fontWeight: '800',
    letterSpacing: -0.8,
    marginTop: 10,
    textAlign: 'center',
  },
  description: {
    color: '#9FB0C7',
    fontSize: 15,
    lineHeight: 22,
    marginTop: 10,
    maxWidth: 360,
    textAlign: 'center',
  },
});
