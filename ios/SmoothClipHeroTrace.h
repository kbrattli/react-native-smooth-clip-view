// Bench instrumentation, not for release (docs/hero-bench.md). Logs
// "[hero-trace] <uptime s> <event>" lines through os_log; the uptime clock is
// CLOCK_UPTIME_RAW, the same clock as CACurrentMediaTime() and React Native's
// performance.now() (ms). Two points: the hardware time of every touch-up
// (SmoothClipView.mm) and the epoch of every run a host installs.
//
// Compiled in only with SMOOTH_CLIP_HERO_TRACE=1 (set by SmoothClipView.podspec
// when `pod install` runs with SMOOTH_CLIP_HERO_TRACE=1 in its environment).
// Off, HERO_TRACE compiles to nothing and the touch swizzle is left out.
#pragma once

#ifndef SMOOTH_CLIP_HERO_TRACE
#define SMOOTH_CLIP_HERO_TRACE 0
#endif

#if SMOOTH_CLIP_HERO_TRACE

#include <os/log.h>
#include <time.h>

static inline double SmoothClipHeroTraceNow(void) {
  return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9;
}

#define HERO_TRACE(fmt, ...)                                           \
  os_log(OS_LOG_DEFAULT, "[hero-trace] %.6f " fmt,                     \
      SmoothClipHeroTraceNow(), ##__VA_ARGS__)

#else

#define HERO_TRACE(fmt, ...) \
  do {                       \
  } while (0)

#endif
