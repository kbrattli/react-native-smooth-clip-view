import type { ReactNode } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { HERO_BACKGROUND } from './heroBenchGeometry';

/**
 * The control bar every bench screen pins below `controlsTop`. Recordings are
 * analysed only above it, so nothing here can be mistaken for the hero.
 */
export function HeroBenchControls({
  children,
  top,
}: {
  children: ReactNode;
  top: number;
}) {
  return <View style={[styles.controls, { top }]}>{children}</View>;
}

export function HeroBenchButton({
  label,
  onPress,
  selected = false,
  testID,
}: {
  label: string;
  onPress: () => void;
  selected?: boolean;
  testID: string;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityState={{ selected }}
      onPress={onPress}
      style={({ pressed }) => [
        styles.button,
        selected ? styles.buttonSelected : null,
        pressed ? styles.buttonPressed : null,
      ]}
      testID={testID}
    >
      <Text
        style={[styles.buttonLabel, selected ? styles.labelSelected : null]}
      >
        {label}
      </Text>
    </Pressable>
  );
}

export function HeroBenchRow({ children }: { children: ReactNode }) {
  return <View style={styles.row}>{children}</View>;
}

export const heroBenchStyles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: HERO_BACKGROUND },
  caption: { color: '#9FB0C7', fontSize: 11, lineHeight: 15 },
});

const styles = StyleSheet.create({
  controls: {
    bottom: 0,
    gap: 6,
    left: 0,
    paddingHorizontal: 12,
    position: 'absolute',
    right: 0,
  },
  row: { flexDirection: 'row', flexWrap: 'wrap', gap: 6 },
  button: {
    backgroundColor: '#0D1B2C',
    borderColor: '#263E59',
    borderRadius: 9,
    borderWidth: StyleSheet.hairlineWidth,
    paddingHorizontal: 10,
    paddingVertical: 7,
  },
  buttonSelected: { backgroundColor: '#66E3FF', borderColor: '#66E3FF' },
  buttonPressed: { opacity: 0.6 },
  buttonLabel: { color: '#F7FAFF', fontSize: 12, fontWeight: '700' },
  labelSelected: { color: '#07111F' },
});
