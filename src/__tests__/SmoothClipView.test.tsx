import { beforeEach, describe, expect, it, jest } from '@jest/globals';
import type { SmoothClipDriver } from '../driverTypes';
import { createDriverState, setDriverState } from '../driverState';
import {
  createClipPresentation,
  type CanonicalSmoothClipPresentation,
} from '../geometry';

let mockPresentationProtocolVersion: 1 | 2 = 2;

jest.mock('../capabilities', () => ({
  getSmoothClipCapabilities: () => ({
    presentationProtocolVersion: mockPresentationProtocolVersion,
  }),
}));

jest.mock('../SmoothClipViewNativeComponent', () => ({
  __esModule: true,
  default: 'NativeSmoothClipView',
}));

import { SmoothClipView } from '../SmoothClipView';

const renderSmoothClipView = (
  SmoothClipView as unknown as {
    render: (
      props: React.ComponentProps<typeof SmoothClipView>,
      ref: null
    ) => React.ReactElement;
  }
).render;

const initialClip = {
  x: 12,
  y: 34,
  width: 280,
  height: 190,
  radius: 20,
};
const initialPresentation = createClipPresentation(initialClip, -12, -34);

function makeDriver(
  driverId = 41,
  presentation: CanonicalSmoothClipPresentation = initialPresentation
): SmoothClipDriver {
  const source = { value: presentation } as never;
  const driver: SmoothClipDriver = {
    kind: 'hybrid',
    presentation: source,
    ui: {
      beginInteraction: () => presentation,
      set: () => undefined,
      setScalars: () => undefined,
      setPresentationScalars: () => undefined,
      animateTo: () => 1,
      cancel: () => presentation,
    },
    react: {
      beginInteraction: async () => presentation,
      set: async () => undefined,
      animateTo: async () => 1,
      cancel: async () => presentation,
    },
  };
  setDriverState(
    driver,
    createDriverState(driverId, presentation, source, {
      current: undefined,
    })
  );
  return driver;
}

describe('SmoothClipView driver boundary', () => {
  beforeEach(() => {
    mockPresentationProtocolVersion = 2;
  });

  it('passes the driver id and complete initial geometry synchronously', () => {
    const element = renderSmoothClipView(
      {
        driver: makeDriver(),
        testID: 'test-clip-host',
        children: 'content',
      },
      null
    );
    const props = element.props as Record<string, unknown>;

    expect(props).toMatchObject({
      driverId: 41,
      initialClipX: 12,
      initialClipY: 34,
      initialClipWidth: 280,
      initialClipHeight: 190,
      initialClipRadius: 20,
      presentationVersion: 2,
      initialClipTopLeftRadius: 20,
      initialClipTopRightRadius: 20,
      initialClipBottomRightRadius: 20,
      initialClipBottomLeftRadius: 20,
      initialClipCurve: 0,
      initialContentTranslateX: -12,
      initialContentTranslateY: -34,
      initialContentScale: 1,
      testID: 'test-clip-host',
      children: 'content',
    });
  });

  it('reuses one driver identity across multiple hosts', () => {
    const driver = makeDriver(73);
    const first = renderSmoothClipView({ driver }, null);
    const second = renderSmoothClipView({ driver }, null);

    expect((first.props as Record<string, unknown>).driverId).toBe(73);
    expect((second.props as Record<string, unknown>).driverId).toBe(73);
  });

  it('keeps a V1-compatible initial presentation on old native', () => {
    mockPresentationProtocolVersion = 1;

    const element = renderSmoothClipView({ driver: makeDriver() }, null);

    expect((element.props as Record<string, unknown>).presentationVersion).toBe(
      1
    );
  });

  it('rejects widened initial channels on old native instead of discarding them', () => {
    mockPresentationProtocolVersion = 1;
    const widened = createClipPresentation(
      {
        ...initialClip,
        topLeftRadius: 28,
        topRightRadius: 16,
        bottomRightRadius: 12,
        bottomLeftRadius: 4,
        curve: 'continuous',
      },
      -12,
      -34,
      0.75
    );

    expect(() =>
      renderSmoothClipView({ driver: makeDriver(42, widened) }, null)
    ).toThrow(/requires native presentation protocol V2/);
  });
});
