#pragma once

#include <cstdint>
#include <functional>
#include <limits>
#include <vector>

namespace smoothclip {

struct Geometry {
  double x;
  double y;
  double width;
  double height;
  double radius;
};

struct Presentation {
  Geometry clip;
  double contentTranslateX;
  double contentTranslateY;
};

struct Keyframe {
  double offset;
  Presentation presentation;
};

struct TimingAnimation {
  double durationMs;
  double controlPoint1X;
  double controlPoint1Y;
  double controlPoint2X;
  double controlPoint2Y;
  int32_t reduceMotion;
};

struct SpringAnimation {
  double mass;
  double stiffness;
  double damping;
  double initialVelocity;
  bool inheritVelocity;
  int32_t reduceMotion;
};

struct AnimationStart {
  bool hasInteractiveStart;
  Presentation interactiveStart;
  // Reanimated-rule start stamp, captured on the UI runtime at animateTo time
  // as `__frameTimestamp || _getAnimationTimestamp()` and converted to
  // CLOCK_MONOTONIC seconds. NaN means no stamp was captured (older callers,
  // tests, platforms that ignore it): the integrator then falls back to its
  // own clock plus the min() frame-clock anchor. iOS constructs this struct
  // without the member and inherits the NaN default — CoreAnimation anchors
  // its own animations, so the hint is Android-only by design.
  double startedAtHintS = std::numeric_limits<double>::quiet_NaN();
};

struct CancelResult {
  bool handled;
  Presentation presentation;
};

using CompletionCallback =
    std::function<void(uint64_t, int32_t, bool)>;

void setCompletionCallback(
    const void *owner,
    CompletionCallback callback);
void clearCompletionCallback(const void *owner);

// recordVelocity gates the 'inherit' velocity-sample recording for this write.
// Default true (the pre-flag behavior); Android's JS layer passes false for
// setScalars hot writes on drivers without SmoothClipDriverOptions
// .velocityTracking, so the per-frame drag stream skips the clock read and
// channel copies. A false write also invalidates any recorded sample pair —
// the geometry moved without being recorded, so surviving samples would
// describe motion the finger never produced. iOS callers never pass it and
// keep recording always.
void setPresentation(
    uint64_t driverId,
    Presentation presentation,
    bool takeOwnership,
    bool overridePendingAnimation = false,
    bool recordVelocity = true);
Presentation beginInteraction(uint64_t driverId);
int32_t animateTiming(
    uint64_t driverId,
    AnimationStart start,
    Presentation presentation,
    TimingAnimation animation);
int32_t animateSpring(
    uint64_t driverId,
    AnimationStart start,
    Presentation presentation,
    SpringAnimation animation);
int32_t animateKeyframes(
    uint64_t driverId,
    AnimationStart start,
    Presentation presentation,
    double durationMs,
    std::vector<Keyframe> keyframes,
    int32_t reduceMotion);
int32_t rejectAnimation(uint64_t driverId);
CancelResult cancelAnimation(
    uint64_t driverId,
    int32_t animationId,
    bool useTarget);
void destroyDriver(uint64_t driverId);

} // namespace smoothclip
