import { Pressable, StyleSheet, Text } from 'react-native';

type ButtonProps = {
  onPress: () => void;
  running: boolean;
};

export function Button({ onPress, running }: ButtonProps) {
  return (
    <Pressable
      accessibilityLabel={running ? 'Stop stress test' : 'Start stress test'}
      accessibilityRole="button"
      onPress={onPress}
      style={({ pressed }) => [
        styles.button,
        running ? styles.buttonRunning : null,
        pressed ? styles.buttonPressed : null,
      ]}
      testID="stress-toggle-animation"
    >
      <Text style={styles.buttonText}>
        {running ? 'Stop and reset' : 'Animate all 10'}
      </Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  button: {
    alignItems: 'center',
    backgroundColor: '#66E3FF',
    borderRadius: 14,
    marginTop: 10,
    minWidth: 170,
    paddingHorizontal: 22,
    paddingVertical: 12,
  },
  buttonRunning: {
    backgroundColor: '#FF9B8F',
  },
  buttonPressed: {
    opacity: 0.72,
    transform: [{ scale: 0.98 }],
  },
  buttonText: {
    color: '#06121F',
    fontSize: 14,
    fontWeight: '800',
  },
});
