import { describe, expect, it, jest } from '@jest/globals';
import type { SmoothClipDriver } from '../driverTypes';
import { createDriverState, setDriverState } from '../driverState';
import { createClipPresentation } from '../geometry';

jest.mock('../SmoothClipViewNativeComponent', () => ({
  __esModule: true,
  default: 'NativeSmoothClipView',
}));

import { SmoothClipView } from '../SmoothClipView';

const initialClip = {
  x: 12,
  y: 34,
  width: 280,
  height: 190,
  radius: 20,
};
const initialPresentation = createClipPresentation(initialClip, -12, -34);

function makeDriver(driverId = 41): SmoothClipDriver {
  const source = { value: initialPresentation } as never;
  const driver: SmoothClipDriver = {
    kind: 'hybrid',
    presentation: source,
    ui: {
      beginInteraction: () => initialPresentation,
      set: () => undefined,
      setScalars: () => undefined,
      animateTo: () => 1,
      cancel: () => initialPresentation,
    },
    react: {
      beginInteraction: async () => initialPresentation,
      set: async () => undefined,
      animateTo: async () => 1,
      cancel: async () => initialPresentation,
    },
  };
  setDriverState(
    driver,
    createDriverState(driverId, initialPresentation, source, {
      current: undefined,
    })
  );
  return driver;
}

describe('SmoothClipView driver boundary', () => {
  it('passes the driver id and complete initial geometry synchronously', () => {
    const element = SmoothClipView({
      driver: makeDriver(),
      testID: 'test-clip-host',
      children: 'content',
    });
    const props = element.props as Record<string, unknown>;

    expect(props).toMatchObject({
      driverId: 41,
      initialClipX: 12,
      initialClipY: 34,
      initialClipWidth: 280,
      initialClipHeight: 190,
      initialClipRadius: 20,
      initialContentTranslateX: -12,
      initialContentTranslateY: -34,
      testID: 'test-clip-host',
      children: 'content',
    });
  });

  it('reuses one driver identity across multiple hosts', () => {
    const driver = makeDriver(73);
    const first = SmoothClipView({ driver });
    const second = SmoothClipView({ driver });

    expect(first.props.driverId).toBe(73);
    expect(second.props.driverId).toBe(73);
  });
});
