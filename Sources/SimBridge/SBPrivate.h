// Declarations of the private classes SimBridge talks to. They are looked up with objc_getClass at runtime;
// these interfaces only give the compiler the selectors (verified against Xcode 27.1 in spike 0A).

#import <AppKit/AppKit.h>
#import "SimBridge.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - CoreSimulator

@interface SimDeviceType : NSObject
@property (readonly) CGSize mainScreenSize;
@property (readonly) float mainScreenScale;
@property (readonly) unsigned int productFamilyID;
@end

@interface SimDevice : NSObject
@property (readonly) NSUUID *UDID;
@property (readonly) NSString *name;
@property (readonly) NSString *stateString;
@property (readonly) SimDeviceType *deviceType;
- (mach_port_t)lookup:(NSString *)name error:(NSError **)error;
- (void)sendAccessibilityRequestAsync:(id)request
                      completionQueue:(dispatch_queue_t)queue
                    completionHandler:(void (^)(id _Nullable response))handler;
@end

@interface SimDeviceSet : NSObject
@property (readonly) NSArray<SimDevice *> *devices;
@end

@interface SimServiceContext : NSObject
+ (nullable instancetype)sharedServiceContextForDeveloperDir:(NSString *)dir error:(NSError **)error;
- (nullable SimDeviceSet *)defaultDeviceSetWithError:(NSError **)error;
@end

#pragma mark - AccessibilityPlatformTranslation

@interface AXPTranslationObject : NSObject <NSCopying>
@property (copy, nullable) NSString *bridgeDelegateToken;
@property int pid;
@end

@interface AXPTranslator : NSObject
+ (instancetype)sharedInstance;
@property (weak, nullable) id bridgeTokenDelegate;
@property BOOL supportsDelegateTokens;
@property BOOL accessibilityEnabled;
- (nullable AXPTranslationObject *)frontmostApplicationWithDisplayId:(unsigned)displayId bridgeDelegateToken:(NSString *)token;
- (nullable AXPTranslationObject *)objectAtPoint:(CGPoint)point displayId:(unsigned)displayId bridgeDelegateToken:(NSString *)token;
- (nullable NSAccessibilityElement *)macPlatformElementFromTranslation:(AXPTranslationObject *)translation;
@end

// AXPMacPlatformElement: an NSAccessibilityElement that forwards attribute reads to the simulator.
@interface NSAccessibilityElement (AXPMacPlatformElement)
@property (readonly, nullable) AXPTranslationObject *translation;
/// One request for several attributes; missing (nil) attributes are absent from the result.
- (nullable id)accessibilityMultipleAttributes:(NSArray<NSString *> *)attributes;
@end

#pragma mark - Helpers

NSError *SBMakeError(SBErrorCode code, NSString *message);

/// The SimDevice behind an SBSimulator.
@interface SBSimulator ()
@property (readonly) SimDevice *device;
@end

NS_ASSUME_NONNULL_END
