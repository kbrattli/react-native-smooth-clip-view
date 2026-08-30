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
  // NaN means "use radius". Keeping the overrides at the end preserves every
  // existing five-value aggregate initializer used by the V1 implementation
  // and its native tests.
  double topLeftRadius = std::numeric_limits<double>::quiet_NaN();
  double topRightRadius = std::numeric_limits<double>::quiet_NaN();
  double bottomRightRadius = std::numeric_limits<double>::quiet_NaN();
  double bottomLeftRadius = std::numeric_limits<double>::quiet_NaN();
  ClipCurve curve = ClipCurve::Circular;
};

struct Presentation {
  Geometry clip;
  double contentTranslateX;
  double contentTranslateY;
  double contentScale = 1.0;
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
  std::vector<Keyframe> keyframes;
};

enum class GroupSuspensionPolicy : int32_t {
  Pause = 0,
  Finish = 1,
};

enum class GroupCancelBehavior : int32_t {
  Freeze = 0,
  Finish = 1,
};

// The seven-scalar V1 bridge predates protocol-V2 host-normalization
// preflight and strict spring/duration rejection. Keep that wire contract
// selectable without widening any V1 entry point; V2 and grouped calls retain
// the conservative validation required for portable native ownership.
enum class AnimationValidationMode : int32_t {
  LegacyV1 = 1,
  ProtocolV2 = 2,
};

using CompletionCallback =
    std::function<void(uint64_t, int32_t, bool)>;
using GroupCompletionCallback =
    std::function<void(uint64_t, int32_t, bool, std::vector<uint64_t>)>;

void setCompletionCallback(
    const void *owner,
    CompletionCallback callback);
void clearCompletionCallback(const void *owner);
void setGroupCompletionCallback(
    const void *owner,
    GroupCompletionCallback callback);
void clearGroupCompletionCallback(const void *owner);

// recordVelocity gates the 'inherit' velocity-sample recording for this write.
// Default true (the pre-flag behavior); Android's JS layer passes false for
// setScalars hot writes on drivers without SmoothClipDriverOptions
// .velocityTracking, so the per-frame drag stream skips the clock read and
// channel copies. iOS callers never pass it and keep recording always.
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
    GroupSuspensionPolicy suspensionPolicy,
    double startedAtHintS = std::numeric_limits<double>::quiet_NaN());
int32_t animateSpringGroup(
    uint64_t controllerId,
    std::vector<GroupMotionEntry> entries,
    SpringAnimation animation,
    GroupSuspensionPolicy suspensionPolicy,
    double startedAtHintS = std::numeric_limits<double>::quiet_NaN());
int32_t animateKeyframesGroup(
    uint64_t controllerId,
    std::vector<GroupMotionEntry> entries,
    double durationMs,
    int32_t reduceMotion,
    GroupSuspensionPolicy suspensionPolicy,
    double startedAtHintS = std::numeric_limits<double>::quiet_NaN());
std::vector<DriverSnapshot> cancelAnimationGroup(
    int32_t groupId,
    GroupCancelBehavior behavior);
int32_t animateTiming(
    uint64_t driverId,
    AnimationStart start,
    Presentation presentation,
    TimingAnimation animation,
    AnimationValidationMode validationMode =
        AnimationValidationMode::ProtocolV2);
int32_t animateSpring(
    uint64_t driverId,
    AnimationStart start,
    Presentation presentation,
    SpringAnimation animation,
    AnimationValidationMode validationMode =
        AnimationValidationMode::ProtocolV2);
int32_t animateKeyframes(
    uint64_t driverId,
    AnimationStart start,
    Presentation presentation,
    double durationMs,
    std::vector<Keyframe> keyframes,
    int32_t reduceMotion,
    AnimationValidationMode validationMode =
        AnimationValidationMode::ProtocolV2);
int32_t rejectAnimation(uint64_t driverId);
CancelResult cancelAnimation(
    uint64_t driverId,
    int32_t animationId,
    bool useTarget);
void destroyDriver(uint64_t driverId);

} // namespace smoothclip
