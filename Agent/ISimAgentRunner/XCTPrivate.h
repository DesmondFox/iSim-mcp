#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Private XCTest calls the public API has no equivalent for, looked up at runtime: which app is in front,
/// and touches synthesized directly through testmanagerd. Public XCUITest gestures wait for the app to go idle
/// before and after every event, which costs seconds per tap (WebDriverAgent bypasses it the same way).
@interface ISimXCT : NSObject

/// Whether the private classes and selectors are all there; without them the agent falls back to public API.
@property (class, readonly) BOOL canSynthesizeEvents;
@property (class, readonly) BOOL canListActiveApplications;

/// Process identifiers of the applications accessibility considers active, in its order.
+ (NSArray<NSNumber *> *)activeApplicationPIDs;

/// The bundle identifier of a running process, from testmanagerd.
+ (nullable NSString *)bundleIdentifierForPID:(pid_t)pid error:(NSError **)error;

/// The interface orientation of an application, or portrait when XCTest does not tell.
+ (UIInterfaceOrientation)interfaceOrientationOfApplication:(id)application;

/// `count` taps at `point`, each held for `hold` seconds.
+ (BOOL)tapAtPoint:(CGPoint)point count:(NSInteger)count hold:(NSTimeInterval)hold
       orientation:(UIInterfaceOrientation)orientation error:(NSError **)error;

/// One finger down at `start`, moving to `end` over `duration` seconds, then up.
+ (BOOL)swipeFrom:(CGPoint)start to:(CGPoint)end duration:(NSTimeInterval)duration
      orientation:(UIInterfaceOrientation)orientation error:(NSError **)error;

/// Presses a key of a hardware keyboard with `modifiers` (XCUIKeyModifierFlags) held; a character or an
/// XCUIKeyboardKey value. One key per event: of several keys in one event path only the first arrives (Xcode 27).
+ (BOOL)pressKey:(NSString *)key modifiers:(NSUInteger)modifiers error:(NSError **)error;
@property (class, readonly) BOOL canPressKeys;

/// Types into whatever has keyboard focus, at most `frequency` characters a second, any script.
+ (BOOL)typeText:(NSString *)text frequency:(NSUInteger)frequency error:(NSError **)error;
@property (class, readonly) BOOL canTypeText;

/// Attributes XCUIElementSnapshot does not declare, e.g. `hasKeyboardFocus`; NO when the snapshot lacks it.
+ (BOOL)snapshot:(id)snapshot boolForKey:(NSString *)key;

@end

NS_ASSUME_NONNULL_END
