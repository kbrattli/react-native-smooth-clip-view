#pragma once

// Debug-only hot-path measurement, the Android sibling of the iOS
// SMOOTH_CLIP_ENABLE_SIGNPOSTS signposts. Compiles to nothing unless
// SMOOTH_CLIP_ENABLE_ATRACE is defined (debug builds only — wired in
// android/build.gradle → CMakeLists.txt). Two sinks per section:
//  - an ATrace slice, visible in Perfetto next to Choreographer#doFrame;
//  - a sampling aggregator that logs mean/p50/p90/p99 to logcat once per
//    window. Individual slices cannot resolve tens-of-nanoseconds deltas
//    (trace write overhead dwarfs them); hundreds of averaged samples can.
// The steady_clock reads add ~2 clock_gettime per section — identical on
// both sides of any before/after comparison, so deltas stay meaningful.
// The per-window flush (three nth_element selections plus one logcat write)
// runs outside the measured slice but INSIDE the caller's frame, once per
// 600 samples. That cost is also identical on both sides of an A/B, so
// differential comparisons cancel it — but absolute ns/call figures from
// tight-loop microbenches (e.g. 10k calls ≈ 16 flushes) include the
// amortized flush, so treat them as comparative, not absolute.

#if defined(SMOOTH_CLIP_ENABLE_ATRACE)

#include <android/log.h>
#include <android/trace.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstddef>

namespace smoothclip::trace {

inline double nowNs() {
  return std::chrono::duration<double, std::nano>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

// Main-thread confined like the registry itself: plain fields, no atomics.
class SectionStats {
 public:
  explicit SectionStats(const char *name) : name_(name) {}

  void record(double durationNs) {
    samples_[count_] = durationNs;
    count_ += 1;
    if (count_ < samples_.size()) return;
    count_ = 0;
    double sum = 0;
    for (const double sample : samples_) sum += sample;
    // Nearest-rank percentiles (index = ceil(q*n/100) - 1) via three O(n)
    // selections instead of a full O(n log n) sort — the buffer is fully
    // overwritten before the next flush, so the reordering is harmless.
    const double p50 = percentile(50);
    const double p90 = percentile(90);
    const double p99 = percentile(99);
    __android_log_print(
        ANDROID_LOG_INFO,
        "SmoothClipTrace",
        "%s n=%zu mean=%.0fns p50=%.0fns p90=%.0fns p99=%.0fns",
        name_,
        samples_.size(),
        sum / static_cast<double>(samples_.size()),
        p50,
        p90,
        p99);
  }

 private:
  double percentile(std::size_t q) {
    const std::size_t index = (samples_.size() * q + 99) / 100 - 1;
    std::nth_element(
        samples_.begin(), samples_.begin() + index, samples_.end());
    return samples_[index];
  }

  const char *name_;
  std::array<double, 600> samples_{};
  std::size_t count_ = 0;
};

class ScopedSection {
 public:
  ScopedSection(const char *name, SectionStats &stats) : stats_(stats) {
    ATrace_beginSection(name);
    startNs_ = nowNs();
  }

  ScopedSection(const ScopedSection &) = delete;
  ScopedSection &operator=(const ScopedSection &) = delete;

  ~ScopedSection() {
    // Duration is captured before record(); the section ends before it so the
    // periodic flush (sort + logcat print) never lands inside the very slice
    // being measured.
    const double durationNs = nowNs() - startNs_;
    ATrace_endSection();
    stats_.record(durationNs);
  }

 private:
  SectionStats &stats_;
  double startNs_ = 0;
};

} // namespace smoothclip::trace

// __COUNTER__-uniqued identifiers so multiple sections can coexist in one
// scope (even on one line) — without this, a second use would be a
// redeclaration that compiles fine in release (empty expansion) and breaks
// only the debug/ATrace build. The id is captured once in the IMPL
// indirection so both references paste the same name. The macro still
// expands to declarations, so it must be a full statement inside a braced
// block — never the unbraced substatement of an `if`/`for`.
#define SMOOTH_CLIP_TRACE_CONCAT2(a, b) a##b
#define SMOOTH_CLIP_TRACE_CONCAT(a, b) SMOOTH_CLIP_TRACE_CONCAT2(a, b)
#define SMOOTH_CLIP_TRACE_IMPL(name, id)                                    \
  static ::smoothclip::trace::SectionStats SMOOTH_CLIP_TRACE_CONCAT(        \
      smoothClipTraceStats_, id){name};                                     \
  ::smoothclip::trace::ScopedSection SMOOTH_CLIP_TRACE_CONCAT(              \
      smoothClipTraceSection_, id) {                                        \
    name, SMOOTH_CLIP_TRACE_CONCAT(smoothClipTraceStats_, id)               \
  }
#define SMOOTH_CLIP_TRACE(name) SMOOTH_CLIP_TRACE_IMPL(name, __COUNTER__)

#else

#define SMOOTH_CLIP_TRACE(name)

#endif
