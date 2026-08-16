#pragma once

#if defined(SMOOTH_CLIP_ENABLE_ATRACE)

#include <android/trace.h>

namespace smoothclip::trace {

class ScopedSection {
 public:
  explicit ScopedSection(const char *name) { ATrace_beginSection(name); }

  ~ScopedSection() { ATrace_endSection(); }
};

} // namespace smoothclip::trace

#define SMOOTH_CLIP_TRACE(name) \
  ::smoothclip::trace::ScopedSection smoothClipTraceSection{name}

#else

#define SMOOTH_CLIP_TRACE(name)

#endif
