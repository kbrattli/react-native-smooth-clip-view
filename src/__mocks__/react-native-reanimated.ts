import { jest } from '@jest/globals';
import { processColor as processColorRN } from 'react-native';

/** Wrapped so tests can count colour parses on the per-frame path. */
export const processColor = jest.fn(processColorRN);

export function useSharedValue<T>(value: T): { value: T } {
  return { value };
}
