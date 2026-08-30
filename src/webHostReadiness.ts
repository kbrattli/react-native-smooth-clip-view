import type { ClipBounds } from './geometry';

type WebRect = Readonly<{ width: number; height: number }>;
export type WebHost = Readonly<{
  isConnected: boolean;
  clientWidth: number;
  clientHeight: number;
  getBoundingClientRect(): WebRect;
  getClientRects(): ReadonlyArray<unknown>;
}>;
type WebDocument = Readonly<{
  visibilityState: string;
  documentElement: object | null;
  addEventListener(type: string, listener: () => void): void;
  removeEventListener(type: string, listener: () => void): void;
}>;
type WebWindow = Readonly<{
  addEventListener(type: string, listener: () => void): void;
  removeEventListener(type: string, listener: () => void): void;
  getComputedStyle(host: WebHost): Readonly<{
    display: string;
    visibility: string;
  }>;
}>;
type WebObserver = { disconnect(): void };
type WebMutationObserver = WebObserver & {
  observe(
    target: object,
    options: Readonly<{
      attributes: boolean;
      childList: boolean;
      subtree: boolean;
    }>
  ): void;
};
type WebRuntime = typeof globalThis & {
  document?: WebDocument;
  window?: WebWindow;
  MutationObserver?: new (callback: () => void) => WebMutationObserver;
  ResizeObserver?: new (callback: () => void) => WebObserver & {
    observe(target: WebHost): void;
  };
};
type LifecycleSubscriber = () => void;

const lifecycleSubscribers = new Set<LifecycleSubscriber>();
let lifecycleMutationObserver: WebMutationObserver | undefined;

function notifyLifecycleSubscribers(): void {
  for (const subscriber of lifecycleSubscribers) subscriber();
}

function subscribeToDocumentLifecycle(
  subscriber: LifecycleSubscriber
): () => void {
  lifecycleSubscribers.add(subscriber);
  const runtime = globalThis as WebRuntime;
  const webDocument = runtime.document;
  const webWindow = runtime.window;
  if (lifecycleSubscribers.size === 1 && webDocument !== undefined) {
    webDocument.addEventListener(
      'visibilitychange',
      notifyLifecycleSubscribers
    );
    webWindow?.addEventListener('resize', notifyLifecycleSubscribers);
    if (
      runtime.MutationObserver !== undefined &&
      webDocument.documentElement !== null
    ) {
      lifecycleMutationObserver = new runtime.MutationObserver(
        notifyLifecycleSubscribers
      );
      lifecycleMutationObserver.observe(webDocument.documentElement, {
        attributes: true,
        childList: true,
        subtree: true,
      });
    }
  }
  return () => {
    lifecycleSubscribers.delete(subscriber);
    if (lifecycleSubscribers.size !== 0 || webDocument === undefined) return;
    webDocument.removeEventListener(
      'visibilitychange',
      notifyLifecycleSubscribers
    );
    webWindow?.removeEventListener('resize', notifyLifecycleSubscribers);
    lifecycleMutationObserver?.disconnect();
    lifecycleMutationObserver = undefined;
  };
}

export function resolveWebHost(value: unknown): WebHost | null {
  const direct = value as Partial<WebHost> | null;
  if (
    direct !== null &&
    typeof direct.getBoundingClientRect === 'function' &&
    typeof direct.getClientRects === 'function'
  ) {
    return direct as WebHost;
  }
  const candidate = (value as { _node?: Partial<WebHost> } | null)?._node;
  return candidate !== undefined &&
    typeof candidate.getBoundingClientRect === 'function' &&
    typeof candidate.getClientRects === 'function'
    ? (candidate as WebHost)
    : null;
}

export function webHostLayoutBounds(host: WebHost): ClipBounds {
  const rect = host.getBoundingClientRect();
  return {
    width: host.clientWidth || rect.width,
    height: host.clientHeight || rect.height,
  };
}

export function webHostIsReady(host: WebHost, bounds: ClipBounds): boolean {
  const runtime = globalThis as WebRuntime;
  const webDocument = runtime.document;
  const webWindow = runtime.window;
  if (
    !host.isConnected ||
    webDocument === undefined ||
    webWindow === undefined ||
    webDocument.visibilityState !== 'visible' ||
    bounds.width <= 0 ||
    bounds.height <= 0
  ) {
    return false;
  }
  const style = webWindow.getComputedStyle(host);
  if (
    style.display === 'none' ||
    style.visibility === 'hidden' ||
    style.visibility === 'collapse'
  ) {
    return false;
  }
  // getClientRects proves the node participates in layout. Its viewport
  // position and opacity are intentionally irrelevant to readiness.
  return host.getClientRects().length > 0;
}

export function observeWebHostReadiness(
  host: WebHost,
  onChange: (bounds: ClipBounds, ready: boolean) => void
): () => void {
  const refresh = () => {
    const bounds = webHostLayoutBounds(host);
    onChange(bounds, webHostIsReady(host, bounds));
  };
  const unsubscribeLifecycle = subscribeToDocumentLifecycle(refresh);
  const ResizeObserverConstructor = (globalThis as WebRuntime).ResizeObserver;
  const resizeObserver =
    ResizeObserverConstructor === undefined
      ? undefined
      : new ResizeObserverConstructor(refresh);
  resizeObserver?.observe(host);
  refresh();
  return () => {
    resizeObserver?.disconnect();
    unsubscribeLifecycle();
  };
}
