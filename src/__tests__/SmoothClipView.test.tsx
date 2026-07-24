import { beforeEach, describe, expect, it, jest } from '@jest/globals';

type Clip = {
  x: number;
  y: number;
  width: number;
  height: number;
  radius: number;
};

const mockNativeRef = { current: null };
let mockReaction: ((clip: Clip, previousClip: Clip | null) => void) | undefined;

jest.mock('react-native-reanimated', () => ({
  __esModule: true,
  default: {
    createAnimatedComponent: (component: unknown) => component,
  },
  dispatchCommand: jest.fn(),
  useAnimatedReaction: (
    _prepare: unknown,
    reaction: (clip: Clip, previousClip: Clip | null) => void
  ) => {
    mockReaction = reaction;
  },
  useAnimatedRef: () => mockNativeRef,
}));

jest.mock('../SmoothClipViewNativeComponent', () => ({
  __esModule: true,
  default: 'NativeSmoothClipView',
}));

import { SmoothClipView } from '../SmoothClipView';
import { dispatchCommand } from 'react-native-reanimated';

const mockDispatchCommand = dispatchCommand as unknown as ReturnType<
  typeof jest.fn
>;

const initialClip: Clip = {
  x: 12,
  y: 34,
  width: 280,
  height: 190,
  radius: 20,
};

function renderSmoothClipView() {
  return SmoothClipView({
    initialClip,
    animatedClip: { value: initialClip } as never,
    testID: 'test-clip-host',
    children: 'content',
  });
}

beforeEach(() => {
  mockDispatchCommand.mockClear();
  mockReaction = undefined;
});

describe('SmoothClipView command boundary', () => {
  it('passes the complete initial clip synchronously to native props', () => {
    const element = renderSmoothClipView();
    const props = element.props as Record<string, unknown>;

    expect(props).toMatchObject({
      initialClipX: 12,
      initialClipY: 34,
      initialClipWidth: 280,
      initialClipHeight: 190,
      initialClipRadius: 20,
      testID: 'test-clip-host',
      children: 'content',
    });
  });

  it('dispatches changed finite geometry through the native command', () => {
    renderSmoothClipView();
    const nextClip = {
      x: 0,
      y: 0,
      width: 390,
      height: 844,
      radius: 20,
    };

    mockReaction?.(nextClip, initialClip);

    expect(mockDispatchCommand).toHaveBeenCalledTimes(1);
    expect(mockDispatchCommand).toHaveBeenCalledWith(
      mockNativeRef,
      'setClipGeometry',
      [0, 0, 390, 844, 20]
    );
  });

  it('ignores duplicate and non-finite geometry', () => {
    renderSmoothClipView();

    mockReaction?.({ ...initialClip }, initialClip);
    mockReaction?.({ ...initialClip, width: Number.NaN }, initialClip);
    mockReaction?.(
      { ...initialClip, x: Number.POSITIVE_INFINITY },
      initialClip
    );

    expect(mockDispatchCommand).not.toHaveBeenCalled();
  });
});
