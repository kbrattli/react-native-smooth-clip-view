#pragma once

#include <cstdint>
#include <functional>
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

void setPresentation(
    uint64_t driverId,
    Presentation presentation,
    bool takeOwnership);
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
