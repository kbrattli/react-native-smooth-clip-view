import { afterEach, describe, expect, it, jest } from '@jest/globals';
import { observeWebHostReadiness, type WebHost } from '../webHostReadiness';

const originalDescriptors = new Map<string, PropertyDescriptor | undefined>();

function installGlobal(name: string, value: unknown): void {
  if (!originalDescriptors.has(name)) {
    originalDescriptors.set(
      name,
      Object.getOwnPropertyDescriptor(globalThis, name)
    );
  }
  Object.defineProperty(globalThis, name, {
    configurable: true,
    writable: true,
    value,
  });
}

afterEach(() => {
  for (const [name, descriptor] of originalDescriptors) {
    if (descriptor === undefined) Reflect.deleteProperty(globalThis, name);
    else Object.defineProperty(globalThis, name, descriptor);
  }
  originalDescriptors.clear();
});

describe('web host readiness', () => {
  it('tracks DOM lifecycle, CSS visibility, positive layout, and relayout', () => {
    const documentListeners = new Map<string, () => void>();
    const windowListeners = new Map<string, () => void>();
    const documentState = {
      visibilityState: 'visible',
      documentElement: {},
      addEventListener: jest.fn((type: string, listener: () => void) => {
        documentListeners.set(type, listener);
      }),
      removeEventListener: jest.fn((type: string) => {
        documentListeners.delete(type);
      }),
    };
    const css = { display: 'block', visibility: 'visible', opacity: '1' };
    installGlobal('document', documentState);
    installGlobal('window', {
      addEventListener: jest.fn((type: string, listener: () => void) => {
        windowListeners.set(type, listener);
      }),
      removeEventListener: jest.fn((type: string) => {
        windowListeners.delete(type);
      }),
      getComputedStyle: jest.fn(() => css),
    });

    let mutationRefresh = () => {};
    let resizeRefresh = () => {};
    const mutationDisconnect = jest.fn();
    const resizeDisconnect = jest.fn();
    installGlobal(
      'MutationObserver',
      class {
        constructor(callback: () => void) {
          mutationRefresh = callback;
        }
        observe() {}
        disconnect() {
          mutationDisconnect();
        }
      }
    );
    installGlobal(
      'ResizeObserver',
      class {
        constructor(callback: () => void) {
          resizeRefresh = callback;
        }
        observe() {}
        disconnect() {
          resizeDisconnect();
        }
      }
    );

    const hostState = {
      connected: true,
      width: 0,
      height: 0,
      laidOut: false,
    };
    const host: WebHost = {
      get isConnected() {
        return hostState.connected;
      },
      get clientWidth() {
        return hostState.width;
      },
      get clientHeight() {
        return hostState.height;
      },
      getBoundingClientRect: () => ({
        width: hostState.width,
        height: hostState.height,
      }),
      getClientRects: () => (hostState.laidOut ? [{}] : []),
    };
    const changes: Array<
      Readonly<{ width: number; height: number; ready: boolean }>
    > = [];
    const stop = observeWebHostReadiness(host, (bounds, ready) => {
      changes.push({ ...bounds, ready });
    });

    expect(changes.at(-1)).toEqual({ width: 0, height: 0, ready: false });
    hostState.width = 240;
    hostState.height = 360;
    hostState.laidOut = true;
    resizeRefresh();
    expect(changes.at(-1)).toEqual({ width: 240, height: 360, ready: true });

    hostState.connected = false;
    mutationRefresh();
    expect(changes.at(-1)?.ready).toBe(false);
    hostState.connected = true;
    mutationRefresh();
    expect(changes.at(-1)?.ready).toBe(true);

    css.visibility = 'hidden';
    mutationRefresh();
    expect(changes.at(-1)?.ready).toBe(false);
    css.visibility = 'visible';
    css.opacity = '0';
    mutationRefresh();
    expect(changes.at(-1)?.ready).toBe(true);

    documentState.visibilityState = 'hidden';
    documentListeners.get('visibilitychange')?.();
    expect(changes.at(-1)?.ready).toBe(false);
    documentState.visibilityState = 'visible';
    documentListeners.get('visibilitychange')?.();
    expect(changes.at(-1)?.ready).toBe(true);

    hostState.width = 320;
    hostState.height = 180;
    resizeRefresh();
    expect(changes.at(-1)).toEqual({ width: 320, height: 180, ready: true });

    stop();
    expect(mutationDisconnect).toHaveBeenCalledTimes(1);
    expect(resizeDisconnect).toHaveBeenCalledTimes(1);
    expect(windowListeners.size).toBe(0);
    expect(documentListeners.size).toBe(0);
  });
});
