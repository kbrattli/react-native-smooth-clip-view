#import "SmoothClipModuleProvider.h"

#import "SmoothClipTurboModule.h"

#import <ReactCommon/CallInvoker.h>
#import <ReactCommon/TurboModule.h>

@implementation SmoothClipModuleProvider

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params {
  return std::make_shared<facebook::react::SmoothClipTurboModule>(
      params.jsInvoker);
}

@end
