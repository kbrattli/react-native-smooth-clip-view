import { describe, expect, it, jest } from '@jest/globals';
import { createElement } from 'react';

jest.mock('../SmoothClipFlightTargetNativeComponent', () => ({
  __esModule: true,
  default: 'NativeSmoothClipFlightTarget',
}));

import { SmoothClipFlightTarget } from '../SmoothClipFlightTarget';

type Rendered = { type: unknown; props: Record<string, unknown> };

function renderTarget(props: Record<string, unknown>): Rendered {
  const element = createElement(SmoothClipFlightTarget, props as never);
  const component = element.type as unknown as {
    render: (props: unknown, ref: unknown) => Rendered;
  };
  return component.render(element.props, null);
}

describe('SmoothClipFlightTarget', () => {
  it('renders the native target with its tag and readiness', () => {
    const rendered = renderTarget({ tag: 'photo-7', testID: 'target' });
    expect(rendered.type).toBe('NativeSmoothClipFlightTarget');
    expect(rendered.props).toMatchObject({
      flightTag: 'photo-7',
      ready: true,
      testID: 'target',
    });
    expect(rendered.props).not.toHaveProperty('tag');
  });

  it('passes ready=false through', () => {
    expect(renderTarget({ tag: 'a', ready: false }).props.ready).toBe(false);
  });
});
