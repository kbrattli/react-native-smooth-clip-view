import { describe, expect, it, jest } from '@jest/globals';
import type { SmoothClipController } from '../controllerTypes';
import { createSmoothClipRef, setControllerRef } from '../controllerInternals';
import { createClipPresentation } from '../geometry';

jest.mock('../SmoothClipBackdropViewNativeComponent', () => ({
  __esModule: true,
  default: 'NativeSmoothClipBackdropView',
}));

import { renderSmoothClipBackdropView } from '../SmoothClipBackdropView';

function makeController(driverId: number): SmoothClipController {
  const controller: SmoothClipController = {
    ref: createSmoothClipRef(driverId),
    ui: {} as never,
    react: {} as never,
  };
  setControllerRef(controller, {
    ref: createSmoothClipRef(driverId),
    initialFrame: createClipPresentation({
      x: 0,
      y: 0,
      width: 100,
      height: 100,
      radius: 8,
    }),
  });
  return controller;
}

describe('SmoothClipBackdropView driver boundary', () => {
  it('binds the native view to the controller by driver id and passes children through', () => {
    const element = renderSmoothClipBackdropView(
      {
        controller: makeController(53),
        testID: 'backdrop',
        style: { flex: 1 },
        children: 'canvas',
      },
      null
    );
    expect(element.type).toBe('NativeSmoothClipBackdropView');
    expect(element.props).toMatchObject({
      driverId: 53,
      testID: 'backdrop',
      style: { flex: 1 },
      children: 'canvas',
    });
  });

  it('rejects a controller that was not created by useSmoothClipController', () => {
    const controller: SmoothClipController = {
      ref: createSmoothClipRef(9),
      ui: {} as never,
      react: {} as never,
    };
    expect(() =>
      renderSmoothClipBackdropView({ controller, children: null }, null)
    ).toThrow('useSmoothClipController');
  });
});
