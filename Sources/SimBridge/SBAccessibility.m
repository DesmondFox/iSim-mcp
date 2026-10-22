#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "SBPrivate.h"

static NSString *const kAXPTPath = @"/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation";

/// The longest a single request to the simulator may take.
static const NSTimeInterval kRequestTimeout = 5;

// Read in one request per element. AXDescription is what iOS calls the label.
static NSArray<NSString *> *SBAttributes(void) {
    return @[@"AXRole", @"AXSubrole", @"AXDescription", @"AXValue", @"AXIdentifier", @"AXPosition", @"AXSize",
             @"AXEnabled", @"AXFocused", @"AXSelected", @"AXChildren"];
}

static id SBEmptyResponse(void) {
    Class responseClass = objc_getClass("AXPTranslatorResponse");
    SEL selector = sel_registerName("emptyResponse");
    return [responseClass respondsToSelector:selector] ? ((id(*)(id, SEL))objc_msgSend)(responseClass, selector) : nil;
}

static NSString *_Nullable SBString(id _Nullable value) {
    if (!value || value == NSNull.null) return nil;
    NSString *string;
    if ([value isKindOfClass:NSAttributedString.class]) {
        string = [value string];
    } else if ([value isKindOfClass:NSString.class]) {
        string = value;
    } else if ([value isKindOfClass:NSNumber.class]) {
        string = [value stringValue];
    } else {
        string = [value description];
    }
    return string.length > 0 ? string : nil;
}

#pragma mark - Element

@interface SBAXElement ()
@property (readwrite, copy, nullable) NSString *role;
@property (readwrite, copy, nullable) NSString *subrole;
@property (readwrite, copy, nullable) NSString *label;
@property (readwrite, copy, nullable) NSString *value;
@property (readwrite, copy, nullable) NSString *identifier;
@property (readwrite) CGRect frame;
@property (readwrite) BOOL enabled;
@property (readwrite) BOOL focused;
@property (readwrite) BOOL selected;
@property (readwrite) int pid;
@property (readwrite, copy) NSArray<SBAXElement *> *children;
@property (readwrite) BOOL truncated;
@end

@implementation SBAXElement

- (instancetype)init {
    if ((self = [super init])) {
        _children = @[];
        _enabled = YES;
    }
    return self;
}

@end

#pragma mark - Bridge

/// One tree read: which simulator answers its requests and until when.
@interface SBAXRead : NSObject
@property (strong) SimDevice *device;
@property (strong) NSDate *deadline;
@property BOOL timedOut;
@end

@implementation SBAXRead
@end

/// AXPTranslator's delegate: routes each request to the simulator of the read that owns the token.
@interface SBAXBridge : NSObject
- (void)beginRead:(SBAXRead *)read token:(NSString *)token;
- (void)endReadWithToken:(NSString *)token;
@end

@implementation SBAXBridge {
    NSMutableDictionary<NSString *, SBAXRead *> *_reads;
}

- (instancetype)init {
    if ((self = [super init])) _reads = [NSMutableDictionary dictionary];
    return self;
}

- (void)beginRead:(SBAXRead *)read token:(NSString *)token {
    @synchronized(_reads) { _reads[token] = read; }
}

- (void)endReadWithToken:(NSString *)token {
    @synchronized(_reads) { [_reads removeObjectForKey:token]; }
}

- (id)accessibilityTranslationDelegateBridgeCallbackWithToken:(NSString *)token {
    SBAXRead *read;
    @synchronized(_reads) { read = _reads[token]; }
    return ^id(id request) {
        // After one timeout the simulator is not answering; fail the rest of the read fast.
        if (!read || read.timedOut) return SBEmptyResponse();
        NSTimeInterval remaining = MIN(read.deadline.timeIntervalSinceNow, kRequestTimeout);
        if (remaining <= 0) {
            read.timedOut = YES;
            return SBEmptyResponse();
        }
        __block id response = nil;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [read.device sendAccessibilityRequestAsync:request
                                   completionQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)
                                 completionHandler:^(id r) {
                                     response = r;
                                     dispatch_semaphore_signal(done);
                                 }];
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC))) != 0) {
            read.timedOut = YES;
            return SBEmptyResponse();
        }
        return response ?: SBEmptyResponse();
    };
}

- (CGRect)accessibilityTranslationConvertPlatformFrameToSystem:(CGRect)rect withToken:(NSString *)token {
    return rect;
}

- (id)accessibilityTranslationRootParentWithToken:(NSString *)token {
    return nil;
}

@end

#pragma mark - Accessibility

@implementation SBAccessibility {
    dispatch_queue_t _queue;
    AXPTranslator *_translator;
    SBAXBridge *_bridge;
}

+ (SBAccessibility *)sharedWithError:(NSError **)error {
    static SBAccessibility *shared;
    static NSError *loadError;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!dlopen(kAXPTPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) {
            loadError = SBMakeError(SBErrorUnavailable, [NSString stringWithFormat:@"Cannot load AccessibilityPlatformTranslation: %s", dlerror()]);
            return;
        }
        Class translatorClass = objc_getClass("AXPTranslator");
        if (![translatorClass respondsToSelector:@selector(sharedInstance)]
            || ![translatorClass instancesRespondToSelector:@selector(frontmostApplicationWithDisplayId:bridgeDelegateToken:)]) {
            loadError = SBMakeError(SBErrorUnavailable, @"AXPTranslator is missing or changed; this macOS is not supported.");
            return;
        }
        shared = [[SBAccessibility alloc] initWithTranslator:[translatorClass sharedInstance]];
    });
    if (!shared && error) *error = loadError;
    return shared;
}

- (instancetype)initWithTranslator:(AXPTranslator *)translator {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("isim.simbridge.accessibility", DISPATCH_QUEUE_SERIAL);
        _bridge = [SBAXBridge new];
        _translator = translator;
        _translator.bridgeTokenDelegate = _bridge;
        _translator.supportsDelegateTokens = YES;
        _translator.accessibilityEnabled = YES;
    }
    return self;
}

- (void)frontmostApplicationOfSimulator:(SBSimulator *)simulator
                               maxDepth:(NSInteger)maxDepth
                            maxElements:(NSInteger)maxElements
                                timeout:(NSTimeInterval)timeout
                             completion:(void (^)(SBAXElement *_Nullable, NSError *_Nullable))completion {
    dispatch_async(_queue, ^{
        @autoreleasepool {
            [self readWithSimulator:simulator timeout:timeout completion:completion body:^SBAXElement *(NSString *token) {
                AXPTranslationObject *application = [self->_translator frontmostApplicationWithDisplayId:0 bridgeDelegateToken:token];
                if (!application) return nil;
                NSInteger budget = MAX(maxElements, 1);
                return [self elementFromTranslation:application token:token depth:0 maxDepth:maxDepth budget:&budget];
            }];
        }
    });
}

- (void)elementAtPoint:(CGPoint)point
             simulator:(SBSimulator *)simulator
               timeout:(NSTimeInterval)timeout
            completion:(void (^)(SBAXElement *_Nullable, NSError *_Nullable))completion {
    dispatch_async(_queue, ^{
        @autoreleasepool {
            [self readWithSimulator:simulator timeout:timeout completion:completion body:^SBAXElement *(NSString *token) {
                AXPTranslationObject *object = [self->_translator objectAtPoint:point displayId:0 bridgeDelegateToken:token];
                if (!object) return nil;
                NSInteger budget = 1;
                return [self elementFromTranslation:object token:token depth:0 maxDepth:0 budget:&budget];
            }];
        }
    });
}

/// Registers a token for the read, runs it and reports a timeout as an error. A fresh token per read keeps
/// the translator's per-token caches from answering with an earlier screen.
- (void)readWithSimulator:(SBSimulator *)simulator
                  timeout:(NSTimeInterval)timeout
               completion:(void (^)(SBAXElement *_Nullable, NSError *_Nullable))completion
                     body:(SBAXElement * (^)(NSString *token))body {
    if (!simulator.isBooted) {
        completion(nil, SBMakeError(SBErrorNotBooted, [NSString stringWithFormat:@"Simulator %@ is not booted.", simulator.udid]));
        return;
    }
    NSString *token = NSUUID.UUID.UUIDString;
    SBAXRead *read = [SBAXRead new];
    read.device = simulator.device;
    read.deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    [_bridge beginRead:read token:token];
    SBAXElement *element = body(token);
    [_bridge endReadWithToken:token];

    if (read.timedOut) {
        completion(nil, SBMakeError(SBErrorTimeout, [NSString stringWithFormat:
            @"The simulator did not answer accessibility requests within %.0f s; it may be busy or still booting.", MIN(timeout, kRequestTimeout)]));
    } else if (!element) {
        completion(nil, SBMakeError(SBErrorAccessibility, @"The simulator reported no element (is it still booting?)."));
    } else {
        completion(element, nil);
    }
}

- (SBAXElement *)elementFromTranslation:(AXPTranslationObject *)translation
                                  token:(NSString *)token
                                  depth:(NSInteger)depth
                               maxDepth:(NSInteger)maxDepth
                                 budget:(NSInteger *)budget {
    translation.bridgeDelegateToken = token;
    NSAccessibilityElement *platform = [_translator macPlatformElementFromTranslation:translation];
    SBAXElement *element = platform ? [self elementFromPlatform:platform token:token depth:depth maxDepth:maxDepth budget:budget] : [SBAXElement new];
    element.pid = translation.pid;
    return element;
}

- (SBAXElement *)elementFromPlatform:(NSAccessibilityElement *)platform
                               token:(NSString *)token
                               depth:(NSInteger)depth
                            maxDepth:(NSInteger)maxDepth
                              budget:(NSInteger *)budget {
    platform.translation.bridgeDelegateToken = token;
    NSDictionary *values = nil;
    if ([platform respondsToSelector:@selector(accessibilityMultipleAttributes:)]) {
        id result = [platform accessibilityMultipleAttributes:SBAttributes()];
        if ([result isKindOfClass:NSDictionary.class]) values = result;
    }
    SBAXElement *element = [SBAXElement new];
    if (values) {
        element.role = SBString(values[@"AXRole"]);
        element.subrole = SBString(values[@"AXSubrole"]);
        element.label = SBString(values[@"AXDescription"]);
        element.value = SBString(values[@"AXValue"]);
        element.identifier = SBString(values[@"AXIdentifier"]);
        id position = values[@"AXPosition"];
        id size = values[@"AXSize"];
        NSPoint origin = [position isKindOfClass:NSValue.class] ? [position pointValue] : NSZeroPoint;
        NSSize extent = [size isKindOfClass:NSValue.class] ? [size sizeValue] : NSZeroSize;
        element.frame = CGRectMake(origin.x, origin.y, extent.width, extent.height);
        element.enabled = values[@"AXEnabled"] ? [values[@"AXEnabled"] boolValue] : YES;
        element.focused = [values[@"AXFocused"] boolValue];
        element.selected = [values[@"AXSelected"] boolValue];
    } else {
        // One request per attribute: slower, same result.
        element.role = SBString(platform.accessibilityRole);
        element.subrole = SBString(platform.accessibilitySubrole);
        element.label = SBString(platform.accessibilityLabel);
        element.value = SBString(platform.accessibilityValue);
        element.identifier = SBString(platform.accessibilityIdentifier);
        element.frame = platform.accessibilityFrame;
        element.enabled = platform.isAccessibilityEnabled;
        element.focused = platform.isAccessibilityFocused;
        element.selected = platform.isAccessibilitySelected;
    }
    element.pid = platform.translation.pid;

    NSArray *children = values ? values[@"AXChildren"] : platform.accessibilityChildren;
    if (![children isKindOfClass:NSArray.class]) children = @[];
    BOOL descend = maxDepth < 0 || depth < maxDepth;
    NSMutableArray<SBAXElement *> *read = [NSMutableArray array];
    for (id child in children) {
        if (!descend || *budget <= 0) {
            element.truncated = YES;
            break;
        }
        if (![child isKindOfClass:NSAccessibilityElement.class]) continue;
        *budget -= 1;
        [read addObject:[self elementFromPlatform:child token:token depth:depth + 1 maxDepth:maxDepth budget:budget]];
    }
    element.children = read;
    return element;
}

@end
