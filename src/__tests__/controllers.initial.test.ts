import { describe, expect, it, jest } from '@jest/globals';
import { processColor } from 'react-native-reanimated';
import type { SmoothClipPresentation } from '../geometry';

// A minimal hook store: refs persist across renders by call order, effects
// run at once. `render` starts a new render pass.
// (`mock` prefix: referenced from the hoisted module factory below.)
const mockRefs: { current: unknown }[] = [];
let mockCursor = 0;

jest.mock('react', () => {
  const actual = jest.requireActual<typeof import('react')>('react');
  return {
    ...actual,
    useEffect: (effect: () => void | (() => void)) => {
      effect();
    },
    useRef: (initial: unknown) => {
      const index = mockCursor++;
      mockRefs[index] ??= { current: initial };
      return mockRefs[index];
    },
  };
});

jest.mock('react-native-worklets', () => ({
  scheduleOnUI: (fn: (...args: never[]) => void, ...args: never[]) =>
    fn(...args),
  scheduleOnRN: (fn: (...args: never[]) => void, ...args: never[]) =>
    fn(...args),
}));

jest.mock('../smoothClipNative', () => ({
  __esModule: true,
  default: {
    setClipPresentation: jest.fn(),
    beginGroupInteraction: jest.fn(),
    snapshotGroup: jest.fn(),
    setClipPresentationBatch: jest.fn(() => true),
    animateTimingGroup: jest.fn(() => 11),
    animateSpringGroup: jest.fn(() => 12),
    cancelAnimationGroup: jest.fn(),
    onClipGroupAnimationComplete: jest.fn(() => ({ remove: jest.fn() })),
  },
}));

jest.mock('../controllerLifecycle', () => ({
  destroyController: jest.fn(),
}));

import { useSmoothClipController } from '../controllers.native';

function render<T>(body: () => T): T {
  mockCursor = 0;
  return body();
}

function presentation(width: number): SmoothClipPresentation {
  return {
    clip: { x: 24, y: 24, width, height: 100, radius: 20 },
    contentTranslateX: 24,
    contentTranslateY: 24,
    boxShadow: {
      color: 'rgba(0, 0, 0, 0.25)',
      offsetX: 0,
      offsetY: 2,
      blurRadius: 16,
    },
  };
}

describe('useSmoothClipController initial frame', () => {
  it('validates and canonicalizes the initial presentation on the first render only', () => {
    // A caller that derives the presentation from layout rebuilds the object
    // every render; only the first render's value seeds the host, so nothing
    // is parsed again (the shadow colour parse stands in for the whole pass).
    const parse = processColor as unknown as jest.Mock;
    parse.mockClear();
    const first = render(() => useSmoothClipController(presentation(360)));
    expect(parse).toHaveBeenCalledTimes(1);
    const second = render(() => useSmoothClipController(presentation(360)));
    expect(second).toBe(first);
    expect(parse).toHaveBeenCalledTimes(1);
    // The first render still rejects an invalid frame.
    mockRefs.length = 0;
    expect(() =>
      render(() =>
        useSmoothClipController({
          ...presentation(360),
          contentTranslateX: Number.NaN,
        })
      )
    ).toThrow('must be finite');
  });
});
