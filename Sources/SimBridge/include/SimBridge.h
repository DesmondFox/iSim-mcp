// Private-API layer for the iOS Simulator: CoreSimulator device lookup, XPC to the `dtuhidd` HID daemon
// inside the simulator, and the accessibility tree through AccessibilityPlatformTranslation.
// Everything is resolved at runtime, so a missing framework or symbol becomes an error instead of a crash.
// The dtuhidd message format lives in Swift (SimBridgeBackend); this layer only moves XPC objects.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <xpc/xpc.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const SBErrorDomain;

typedef NS_ERROR_ENUM(SBErrorDomain, SBErrorCode) {
    /// A private framework or symbol is missing (Xcode changed).
    SBErrorUnavailable = 1,
    SBErrorDeviceNotFound = 2,
    SBErrorNotBooted = 3,
    /// The simulator has no such mach service, or the lookup failed.
    SBErrorLookupFailed = 4,
    SBErrorTimeout = 5,
    SBErrorAccessibility = 6,
};

// The classes are immutable or synchronize internally, so Swift may pass them between tasks.

/// A simulator from the default device set of an Xcode.
NS_SWIFT_SENDABLE
@interface SBSimulator : NSObject

/// Finds the simulator by UDID through CoreSimulator of the given developer directory.
+ (nullable instancetype)simulatorWithUDID:(NSString *)udid developerDir:(NSString *)developerDir error:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;

@property (readonly, copy) NSString *udid;
@property (readonly, copy) NSString *name;
/// Read live from CoreSimulator.
@property (readonly) BOOL isBooted;
/// Main screen in points, in the native (portrait) orientation.
@property (readonly) CGSize screenSize;
/// 1 iPhone, 2 iPad.
@property (readonly) NSInteger productFamily;

@end

/// A plain XPC connection to a mach service in the simulator's bootstrap namespace.
NS_SWIFT_SENDABLE
@interface SBXPCConnection : NSObject

/// Looks the service up and resumes the connection. Says nothing about whether the service answers.
- (nullable instancetype)initWithSimulator:(SBSimulator *)simulator service:(NSString *)service error:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;

- (void)sendMessage:(xpc_object_t)message;

/// Calls back with the reply, an XPC error object, or nil when `timeout` passes first.
- (void)sendMessage:(xpc_object_t)message timeout:(NSTimeInterval)timeout completion:(void (^)(xpc_object_t _Nullable reply))completion;

/// Calls back once everything sent before has left this process.
- (void)flushWithCompletion:(void (^)(void))completion;

- (void)cancel;

/// Grows each time the peer exits; XPC relaunches it on the next send.
@property (readonly) NSUInteger interruptions;
/// The connection is gone for good (the simulator shut down); make a new one.
@property (readonly) BOOL isInvalidated;

@end

/// One node of an accessibility tree. Frames are in points, in the interface orientation.
NS_SWIFT_SENDABLE
@interface SBAXElement : NSObject

@property (readonly, copy, nullable) NSString *role;
@property (readonly, copy, nullable) NSString *subrole;
@property (readonly, copy, nullable) NSString *label;
@property (readonly, copy, nullable) NSString *value;
@property (readonly, copy, nullable) NSString *identifier;
@property (readonly) CGRect frame;
@property (readonly) BOOL enabled;
@property (readonly) BOOL focused;
@property (readonly) BOOL selected;
@property (readonly) int pid;
@property (readonly, copy) NSArray<SBAXElement *> *children;
/// Children were not read because of the depth or element limit.
@property (readonly) BOOL truncated;

@end

/// Reads accessibility trees of simulators. Requests run one at a time on a private queue.
NS_SWIFT_SENDABLE
@interface SBAccessibility : NSObject

/// Loads AccessibilityPlatformTranslation once.
+ (nullable SBAccessibility *)sharedWithError:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;

/// The frontmost application with its descendants. `maxDepth` 0 reads only the application element.
/// Stops reading new elements after `maxElements` and fails when the whole read takes longer than `timeout`.
- (void)frontmostApplicationOfSimulator:(SBSimulator *)simulator
                               maxDepth:(NSInteger)maxDepth
                            maxElements:(NSInteger)maxElements
                                timeout:(NSTimeInterval)timeout
                             completion:(void (^)(SBAXElement *_Nullable application, NSError *_Nullable error))completion;

/// The deepest element at a point (in points, interface orientation), without its children.
- (void)elementAtPoint:(CGPoint)point
             simulator:(SBSimulator *)simulator
               timeout:(NSTimeInterval)timeout
            completion:(void (^)(SBAXElement *_Nullable element, NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
