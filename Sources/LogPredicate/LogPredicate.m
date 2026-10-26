#import "LogPredicate.h"

@implementation ISLogPredicate {
    NSPredicate *_predicate;
}

- (nullable instancetype)initWithFormat:(NSString *)format error:(NSString **)error {
    if (!(self = [super init])) return nil;
    @try {
        _predicate = [NSPredicate predicateWithFormat:format];
    } @catch (NSException *exception) {
        if (error) *error = exception.reason ?: exception.name;
        return nil;
    }
    return self;
}

- (BOOL)matches:(NSDictionary<NSString *, id> *)fields {
    @try {
        return [_predicate evaluateWithObject:fields];
    } @catch (NSException *exception) {
        return NO;
    }
}

@end
