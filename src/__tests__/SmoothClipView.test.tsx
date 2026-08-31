import { describe, expect, it, jest } from '@jest/globals';
import type { SmoothClipDriver } from '../driverTypes';
import { createDriverState, setDriverState } from '../driverState';
import {
  createClipPresentation,
  type CanonicalSmoothClipPresentation,
} from '../geometry';

jest.mock('../SmoothClipViewNativeComponent', () => ({
  __esModule: true,
  default: 'NativeSmoothClipView',
}));

import { sanitizeSmoothClipStyle, SmoothClipView } from '../SmoothClipView';

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
    presentation: source,
    ui: {
      beginInteraction: () => presentation,
      set: () => undefined,
      setScalars: () => undefined,
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

  it('packs the complete initial box shadow into native props', () => {
    const presentation = createClipPresentation(initialClip, -12, -34, 0.75, {
      color: '#33669980',
      offsetX: -2,
      offsetY: 5,
      blurRadius: 64,
      spreadDistance: 7,
    });
    const element = renderSmoothClipView(
      { driver: makeDriver(91, presentation) },
      null
    );

    expect(element.props).toMatchObject({
      initialClipBoxShadowEnabled: true,
      initialClipBoxShadowRed: 0x33 / 255,
      initialClipBoxShadowGreen: 0x66 / 255,
      initialClipBoxShadowBlue: 0x99 / 255,
      initialClipBoxShadowAlpha: 0x80 / 255,
      initialClipBoxShadowOffsetX: -2,
      initialClipBoxShadowOffsetY: 5,
      initialClipBoxShadowBlurRadius: 64,
      initialClipBoxShadowSpreadDistance: 7,
    });
  });

  it('sanitizes every independent React Native shadow style', () => {
    const error = jest.spyOn(console, 'error').mockImplementation(() => {});
    expect(
      sanitizeSmoothClipStyle({
        opacity: 0.5,
        boxShadow: '0 2px 8px #000',
        shadowColor: '#000',
        shadowOpacity: 0.2,
        shadowRadius: 4,
        elevation: 5,
        filter: 'drop-shadow(0 2px 4px #000)',
      })
    ).toEqual({ opacity: 0.5 });

    expect(
      sanitizeSmoothClipStyle({
        filter: [
          { brightness: 0.8 },
          { dropShadow: { offsetX: 0, offsetY: 2, standardDeviation: 4 } },
          { contrast: 1.1 },
        ],
      })
    ).toEqual({ filter: [{ brightness: 0.8 }, { contrast: 1.1 }] });

    expect(
      sanitizeSmoothClipStyle({
        filter: 'brightness(0.8) drop-shadow(0 2px 4px rgba(0,0,0,.3))',
      })
    ).toEqual({ filter: 'brightness(0.8)' });
    expect(error).toHaveBeenCalledWith(
      expect.stringContaining('SmoothClipPresentation.boxShadow')
    );
    error.mockRestore();
  });
});
