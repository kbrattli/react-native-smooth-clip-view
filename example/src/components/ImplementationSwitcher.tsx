import { Pressable, StyleSheet, Text, View } from 'react-native';
import type { StressImplementation } from './StressTestScreen';

type ImplementationSwitcherProps = {
  implementation: StressImplementation;
  onChange: (implementation: StressImplementation) => void;
};

const OPTIONS: readonly {
  label: string;
  value: StressImplementation;
}[] = [
  { label: 'Legacy', value: 'legacy' },
  { label: 'Direct', value: 'direct' },
  { label: 'Scalars', value: 'scalar' },
  { label: 'Native CA', value: 'native' },
  { label: 'Layout', value: 'animated-layout' },
];

export function ImplementationSwitcher({
  implementation,
  onChange,
}: ImplementationSwitcherProps) {
  return (
    <View
      accessibilityRole="tablist"
      style={styles.container}
      testID="stress-screen-selector"
    >
      {OPTIONS.map((option) => {
        const selected = option.value === implementation;

        return (
          <Pressable
            accessibilityRole="tab"
            accessibilityState={{ selected }}
            key={option.value}
            onPress={() => onChange(option.value)}
            style={({ pressed }) => [
              styles.option,
              selected ? styles.optionSelected : null,
              pressed ? styles.optionPressed : null,
            ]}
            testID={`stress-screen-${option.value}`}
          >
            <Text
              style={[
                styles.optionLabel,
                selected ? styles.optionLabelSelected : null,
              ]}
            >
              {option.label}
            </Text>
          </Pressable>
        );
      })}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    alignSelf: 'center',
    backgroundColor: '#0D1B2C',
    borderColor: '#263E59',
    borderRadius: 14,
    borderWidth: StyleSheet.hairlineWidth,
    flexDirection: 'row',
    marginHorizontal: 18,
    marginTop: 18,
    maxWidth: 430,
    padding: 4,
    width: '90%',
  },
  option: {
    alignItems: 'center',
    borderRadius: 10,
    flex: 1,
    paddingHorizontal: 8,
    paddingVertical: 10,
  },
  optionSelected: {
    backgroundColor: '#66E3FF',
  },
  optionPressed: {
    opacity: 0.72,
  },
  optionLabel: {
    color: '#9FB0C7',
    fontSize: 11,
    fontWeight: '800',
  },
  optionLabelSelected: {
    color: '#06121F',
  },
});
