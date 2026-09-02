import { describe, expect, it, jest } from '@jest/globals';
import type { SmoothClipController } from '../controllerTypes';
import { createSmoothClipRef, setControllerRef } from '../controllerInternals';
import {
  createClipPresentation,
  type CanonicalSmoothClipPresentation,
} from '../geometry';

jest.mock('../SmoothClipViewNativeComponent', () => ({
  __esModule: true,
  default: 'NativeSmoothClipView',
}));

import {
  renderSmoothClipView,
  sanitizeSmoothClipStyle,
} from '../SmoothClipView';

const initialClip = {
  x: 12,
  y: 34,
  width: 280,
  height: 190,
  radius: 20,
};
const initialPresentation = createClipPresentation(initialClip, -12, -34);

function makeController(
  driverId = 41,
  presentation: CanonicalSmoothClipPresentation = initialPresentation
): SmoothClipController {
  const controller: SmoothClipController = {
    ref: createSmoothClipRef(driverId),
    ui: {} as never,
    react: {} as never,
  };
  setControllerRef(controller, {
    ref: createSmoothClipRef(driverId),
    initialFrame: presentation,
  });
  return controller;
}

describe('SmoothClipView driver boundary', () => {
  it('passes the driver id and complete initial geometry synchronously', () => {
    const element = renderSmoothClipView(
      {
        controller: makeController(),
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

  it('passes one controller identity to its host', () => {
    const controller = makeController(73);
    const first = renderSmoothClipView({ controller }, null);

    expect((first.props as Record<string, unknown>).driverId).toBe(73);
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
      { controller: makeController(91, presentation) },
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
