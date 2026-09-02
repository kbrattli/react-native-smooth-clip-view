#pragma once

#include <cstdint>
#include <functional>
#include <limits>
#include <vector>

namespace smoothclip {

enum class ClipCurve : int32_t {
  Circular = 0,
  Continuous = 1,
};

struct Geometry {
  double x;
  double y;
  double width;
  double height;
  double radius;
  // NaN means "use radius", allowing concise uniform-radius presentations.
  double topLeftRadius = std::numeric_limits<double>::quiet_NaN();
  double topRightRadius = std::numeric_limits<double>::quiet_NaN();
  double bottomRightRadius = std::numeric_limits<double>::quiet_NaN();
  double bottomLeftRadius = std::numeric_limits<double>::quiet_NaN();
  ClipCurve curve = ClipCurve::Circular;
};

struct Shadow {
  bool enabled = false;
  double red = 0;
  double green = 0;
  double blue = 0;
  double alpha = 1;
  double offsetX = 0;
  double offsetY = 0;
  double blurRadius = 0;
  double spreadDistance = 0;
};

struct Presentation {
  Geometry clip;
  double contentTranslateX;
  double contentTranslateY;
  double contentScale = 1.0;
  Shadow shadow{};
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
  double energyThreshold = 6e-9;
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

struct DriverSnapshot {
  uint64_t driverId;
  Presentation presentation;
  bool ready;
};

struct BatchEntry {
  uint64_t driverId;
  Presentation presentation;
};

struct GroupMotionEntry {
  uint64_t driverId;
  bool hasFrom;
  Presentation from;
  Presentation target;
};

enum class GroupCancelBehavior : int32_t {
  Freeze = 0,
  Finish = 1,
};

using CompletionCallback =
    std::function<void(uint64_t, int32_t, int32_t, bool)>;
using GroupCompletionCallback =
    std::function<
        void(uint64_t, int32_t, int32_t, bool, std::vector<DriverSnapshot>)>;

void setCompletionCallback(
    const void *owner,
    CompletionCallback callback);
void clearCompletionCallback(const void *owner);
void setGroupCompletionCallback(
    const void *owner,
    GroupCompletionCallback callback);
void clearGroupCompletionCallback(const void *owner);

// Interactive writes always keep the two samples needed by a later
// `initialVelocity: "inherit"` spring.
void setPresentation(
    uint64_t driverId,
    Presentation presentation,
    bool takeOwnership,
    bool overridePendingAnimation = false,
    bool recordVelocity = true);
Presentation beginInteraction(uint64_t driverId);
Presentation snapshotCurrent(uint64_t driverId);
std::vector<DriverSnapshot> beginGroupInteraction(
    const std::vector<uint64_t> &driverIds);
std::vector<DriverSnapshot> snapshotGroup(
    const std::vector<uint64_t> &driverIds);
bool setPresentationBatch(const std::vector<BatchEntry> &entries);
int32_t animateTimingGroup(
    uint64_t controllerId,
    std::vector<GroupMotionEntry> entries,
    TimingAnimation animation,
    int32_t completionTag = 0,
    double startedAtHintS = std::numeric_limits<double>::quiet_NaN());
int32_t animateSpringGroup(
    uint64_t controllerId,
    std::vector<GroupMotionEntry> entries,
    SpringAnimation animation,
    int32_t completionTag = 0,
    double startedAtHintS = std::numeric_limits<double>::quiet_NaN());
std::vector<DriverSnapshot> cancelAnimationGroup(
    int32_t groupId,
    GroupCancelBehavior behavior);
int32_t animateTiming(
    uint64_t driverId,
    AnimationStart start,
    Presentation presentation,
    TimingAnimation animation,
    int32_t completionTag = 0);
int32_t animateSpring(
    uint64_t driverId,
    AnimationStart start,
    Presentation presentation,
    SpringAnimation animation,
    int32_t completionTag = 0);
int32_t rejectAnimation(uint64_t driverId);
CancelResult cancelAnimation(
    uint64_t driverId,
    int32_t animationId,
    bool useTarget);
void destroyDriver(uint64_t driverId);

} // namespace smoothclip
