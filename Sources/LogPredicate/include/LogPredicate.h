// NSPredicate for log entries read off an iPhone: `log`'s predicate syntax, checked on the Mac because
// os_trace_relay cannot filter. NSPredicate reports bad syntax and impossible comparisons with Objective-C
// exceptions, which Swift cannot catch; this layer turns them into an error and a non-match.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NS_SWIFT_SENDABLE
@interface ISLogPredicate : NSObject

/// nil, with `error` set to NSPredicate's reason, when the format does not parse.
- (nullable instancetype)initWithFormat:(NSString *)format error:(NSString *_Nullable *_Nullable)error;

/// Whether an entry's fields (`process`, `subsystem`, `composedMessage`, …) satisfy the predicate;
/// NO when it cannot be evaluated on them, e.g. CONTAINS on a number.
- (BOOL)matches:(NSDictionary<NSString *, id> *)fields;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
