#import <dlfcn.h>
#import <objc/runtime.h>

#import "SBPrivate.h"

NSErrorDomain const SBErrorDomain = @"SimBridge";

NSError *SBMakeError(SBErrorCode code, NSString *message) {
    return [NSError errorWithDomain:SBErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *const kCoreSimulatorPath = @"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator";

/// The device set of an Xcode; CoreSimulator keeps it in sync with simctl.
static SimDeviceSet *_Nullable SBDeviceSet(NSString *developerDir, NSError **error) {
    static NSMutableDictionary<NSString *, SimDeviceSet *> *sets;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sets = [NSMutableDictionary dictionary];
    });
    @synchronized(sets) {
        SimDeviceSet *set = sets[developerDir];
        if (set) return set;
        if (!dlopen(kCoreSimulatorPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) {
            if (error) *error = SBMakeError(SBErrorUnavailable, [NSString stringWithFormat:@"Cannot load CoreSimulator: %s", dlerror()]);
            return nil;
        }
        Class contextClass = objc_getClass("SimServiceContext");
        if (![contextClass respondsToSelector:@selector(sharedServiceContextForDeveloperDir:error:)]) {
            if (error) *error = SBMakeError(SBErrorUnavailable, @"CoreSimulator has no SimServiceContext; this Xcode is not supported.");
            return nil;
        }
        NSError *underlying = nil;
        SimServiceContext *context = [contextClass sharedServiceContextForDeveloperDir:developerDir error:&underlying];
        set = [context defaultDeviceSetWithError:&underlying];
        if (!set) {
            if (error) *error = SBMakeError(SBErrorUnavailable, [NSString stringWithFormat:@"CoreSimulator device set: %@", underlying.localizedDescription ?: @"unknown error"]);
            return nil;
        }
        sets[developerDir] = set;
        return set;
    }
}

@implementation SBSimulator

+ (instancetype)simulatorWithUDID:(NSString *)udid developerDir:(NSString *)developerDir error:(NSError **)error {
    SimDeviceSet *set = SBDeviceSet(developerDir, error);
    if (!set) return nil;
    for (SimDevice *device in set.devices) {
        if ([device.UDID.UUIDString caseInsensitiveCompare:udid] == NSOrderedSame) {
            return [[self alloc] initWithDevice:device];
        }
    }
    if (error) *error = SBMakeError(SBErrorDeviceNotFound, [NSString stringWithFormat:@"CoreSimulator does not know simulator %@.", udid]);
    return nil;
}

- (instancetype)initWithDevice:(SimDevice *)device {
    if ((self = [super init])) {
        _device = device;
        _udid = [device.UDID.UUIDString copy];
        _name = [device.name copy];
    }
    return self;
}

- (BOOL)isBooted {
    return [self.device.stateString isEqualToString:@"Booted"];
}

- (CGSize)screenSize {
    SimDeviceType *type = self.device.deviceType;
    CGFloat scale = type.mainScreenScale > 0 ? type.mainScreenScale : 1;
    return CGSizeMake(type.mainScreenSize.width / scale, type.mainScreenSize.height / scale);
}

- (NSInteger)productFamily {
    SimDeviceType *type = self.device.deviceType;
    return [type respondsToSelector:@selector(productFamilyID)] ? type.productFamilyID : 1;
}

@end
