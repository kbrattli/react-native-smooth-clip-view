# LegendList exact initial layout patch

## Problem

The fixed horizontal pager in
[`ZoomOverlay`](../example/src/components/ZoomOverlay.tsx) opens inside an
animated transparent modal. Its viewport size, page size, dataset, and
`initialScrollIndex` are all known before mount.

`@legendapp/list` 3.3.10 still treats that initial geometry as unmeasured on
native Fabric. Its normal mount sequence:

1. withholds the item containers until the first layout measurement;
2. mounts the native scroll view before the final content extent exists;
3. resolves `initialScrollIndex` through later bootstrap passes; and
4. keeps the container layer hidden until full list readiness.

The surrounding clip animation can therefore begin while the requested page is
absent. Opening a page after index 0 exposes the card underneath the transparent
modal, then reveals the requested page after the animation has already
progressed. The visible problem is caused by missing first-commit list content,
not by the clip animation's start time.

## Solution

The repository carries the fix as
[`patches/@legendapp+list+3.3.10.patch`](../patches/@legendapp+list+3.3.10.patch).
It adds an explicit `experimental_exactInitialLayout` contract for native
Fabric lists whose initial geometry can be proven synchronously.

`ZoomOverlay` opts in for its fixed full-screen pager:

```tsx
<LegendList
  estimatedListSize={{ width: SCREEN_WIDTH, height: SCREEN_HEIGHT }}
  experimental_exactInitialLayout={{
    width: SCREEN_WIDTH,
    height: SCREEN_HEIGHT,
  }}
  getFixedItemSize={getFixedItemSize}
  horizontal
  initialScrollIndex={openingIndex}
  // ...
/>
```

`estimatedListSize` remains a performance hint. The new object-valued prop is a
separate correctness guarantee: the declared viewport and every value returned
by `getFixedItemSize` must be exact.

### First-commit initialization

For an eligible list, the patch resolves one exact geometry snapshot before the
initial native commit. That snapshot supplies:

- every initial item size and position;
- the total content extent;
- the clamped offset for the requested `initialScrollIndex`;
- the initial container pool and target render window; and
- the same offset for LegendList's internal scroll state and the native
  scroll view's `contentOffset`.

The requested page is therefore allocated, positioned, and visible in the first
Fabric commit instead of being introduced after layout and scroll bootstrap.

### Readiness and fallback behavior

The patch adds a mount-only `initialContentVisible` state rather than marking
the whole list ready early. The proven initial containers can render at opacity
1, while normal `readyToRender` behavior still controls pointer interaction,
`onLoad`, adaptive rendering, and the rest of the list lifecycle.

The exact path currently requires:

- native Fabric;
- positive finite viewport dimensions;
- non-empty initial data;
- a single column;
- an in-range integer `initialScrollIndex`;
- a positive finite fixed size for every initial item; and
- no layout modifier whose initial contribution requires post-mount
  measurement.

Unsupported configurations warn once in development and use LegendList's
existing initial-scroll path. Horizontal RTL, headers, footers, separators,
gaps, content insets, active refresh controls, custom layout or scroll
components, sticky headers, snap indices, window scrolling, anchored end space,
and end alignment are not eligible.

The first measured viewport must match the declared viewport within one point.
A mismatch invalidates the exact path, hides the mount-only content, warns in
development, and resumes normal bootstrap convergence. Layout or initial-scroll
resets also invalidate the snapshot so stale data cannot retain early
visibility.

### Platform settlement

iOS and Android share the exact geometry, target allocation, content extent,
scroll seed, native `contentOffset`, and first-commit visibility.

After measurement, iOS may finish initial-scroll settlement without an
imperative correction when the measured viewport, mounted items, resolved
offset, and observed native offset all match the seed. Android retains
LegendList's existing final corrective scroll because its native scroll view
may discard a mount-time offset while content materializes.

The correction policy is platform-specific, but first-commit correctness is
shared: the requested page is present before the modal animation displays its
first expanding frame.
