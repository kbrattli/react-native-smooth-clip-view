import { Pressable, StyleSheet, Text } from 'react-native';

type ButtonProps = {
  expanded: boolean;
  onPress: () => void;
};

export function Button({ expanded, onPress }: ButtonProps) {
  return (
    <Pressable
      accessibilityRole="button"
      onPress={onPress}
      style={({ pressed }) => [
        styles.button,
        pressed ? styles.buttonPressed : null,
      ]}
    >
      <Text style={styles.buttonText}>
        {expanded ? 'Collapse clip' : 'Expand clip'}
      </Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  button: {
    alignItems: 'center',
    backgroundColor: '#66E3FF',
    borderRadius: 16,
    marginTop: 24,
    minWidth: 180,
    paddingHorizontal: 24,
    paddingVertical: 15,
  },
  buttonPressed: {
    opacity: 0.72,
    transform: [{ scale: 0.98 }],
  },
  buttonText: {
    color: '#06121F',
    fontSize: 15,
    fontWeight: '800',
  },
});
