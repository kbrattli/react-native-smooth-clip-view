/**
 * Exact cubic-Bézier control points for the standard polynomial easings, for
 * use as `TimingClipAnimation.controlPoints`.
 *
 * Native transitions and a parallel Reanimated animation (content driven by
 * `withTiming` alongside a native `animateTo`) only stay in sync when both
 * sides run the identical curve. Each entry below is the exact single-Bézier
 * form of the matching Reanimated easing — not an approximation — so pairing
 * e.g. `Easing.out(Easing.cubic)` with `ClipEasings.easeOutCubic` is
 * mathematically lossless:
 *
 * - `linear`       ↔ `Easing.linear`
 * - `easeInQuad`   ↔ `Easing.in(Easing.quad)`
 * - `easeOutQuad`  ↔ `Easing.out(Easing.quad)`
 * - `easeInCubic`  ↔ `Easing.in(Easing.cubic)`
 * - `easeOutCubic` ↔ `Easing.out(Easing.cubic)`
 *
 * With x-control-points at 1/3 and 2/3 the Bézier's x(t) is the identity, so
 * y(t) is the easing polynomial itself (e.g. `easeOutCubic`: y = 1 − (1−t)³).
 *
 * `Easing.inOut(Easing.cubic)` (and the other `inOut` polynomials) are
 * piecewise and have NO exact single-Bézier form — for those, define one
 * `Easing.bezier(x1, y1, x2, y2)` and pass the same four numbers as
 * `controlPoints` so both sides share the same (approximated) curve.
 */
export const ClipEasings = {
  linear: [0, 0, 1, 1],
  easeInQuad: [1 / 3, 0, 2 / 3, 1 / 3],
  easeOutQuad: [1 / 3, 2 / 3, 2 / 3, 1],
  easeInCubic: [1 / 3, 0, 2 / 3, 0],
  easeOutCubic: [1 / 3, 1, 2 / 3, 1],
} as const satisfies Record<string, readonly [number, number, number, number]>;
