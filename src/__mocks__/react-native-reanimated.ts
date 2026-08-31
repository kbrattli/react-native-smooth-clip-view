import { processColor as processColorRN } from 'react-native';

export const processColor = processColorRN;

export function useSharedValue<T>(value: T): { value: T } {
  return { value };
}
