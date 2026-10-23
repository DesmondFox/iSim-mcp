#import "XCTPrivate.h"
#import <objc/message.h>

static NSString *const ISimXCTErrorDomain = @"ISimXCT";

static NSError *ISimError(NSString *message) {
  return [NSError errorWithDomain:ISimXCTErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static id ISimSend(id target, NSString *selector) {
  SEL sel = NSSelectorFromString(selector);
  if (target == nil || ![target respondsToSelector:sel]) return nil;
  return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

/// Waits for a reply that may arrive on any queue, the main one included: the agent handles requests
/// on the main thread, so the main run loop keeps turning while it waits.
static BOOL ISimWait(dispatch_semaphore_t semaphore, NSTimeInterval timeout) {
  if (![NSThread isMainThread]) {
    return dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) == 0;
  }
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while (dispatch_semaphore_wait(semaphore, DISPATCH_TIME_NOW) != 0) {
    if ([deadline timeIntervalSinceNow] <= 0) return NO;
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
  }
  return YES;
}

@implementation ISimXCT

+ (id)daemonSession {
  return ISimSend(NSClassFromString(@"XCTRunnerDaemonSession"), @"sharedSession");
}

/// XCTest's accessibility client (XCAXClient_iOS), which XCUIDevice owns.
+ (id)accessibilityClient {
  id device = ISimSend(NSClassFromString(@"XCUIDevice"), @"sharedDevice");
  return ISimSend(device, @"accessibilityInterface");
}

+ (BOOL)canSynthesizeEvents {
  Class path = NSClassFromString(@"XCPointerEventPath");
  Class record = NSClassFromString(@"XCSynthesizedEventRecord");
  return path && record
    && [path instancesRespondToSelector:NSSelectorFromString(@"initForTouchAtPoint:offset:")]
    && [path instancesRespondToSelector:NSSelectorFromString(@"liftUpAtOffset:")]
    && [path instancesRespondToSelector:NSSelectorFromString(@"pressDownAtOffset:")]
    && [path instancesRespondToSelector:NSSelectorFromString(@"moveToPoint:atOffset:")]
    && [record instancesRespondToSelector:NSSelectorFromString(@"initWithName:interfaceOrientation:")]
    && [record instancesRespondToSelector:NSSelectorFromString(@"addPointerEventPath:")]
    && [[self daemonSession] respondsToSelector:NSSelectorFromString(@"synthesizeEvent:completion:")];
}

+ (BOOL)canListActiveApplications {
  id client = [self accessibilityClient];
  id proxy = ISimSend([self daemonSession], @"daemonProxy");
  return [client respondsToSelector:NSSelectorFromString(@"activeApplications")]
    && [proxy respondsToSelector:NSSelectorFromString(@"_XCT_requestBundleIDForPID:reply:")];
}

+ (NSArray<NSNumber *> *)activeApplicationPIDs {
  id client = [self accessibilityClient];
  NSArray *elements = ISimSend(client, @"activeApplications");
  NSMutableArray<NSNumber *> *pids = [NSMutableArray array];
  SEL processIdentifier = NSSelectorFromString(@"processIdentifier");
  for (id element in elements) {
    if (![element respondsToSelector:processIdentifier]) continue;
    pid_t pid = ((pid_t (*)(id, SEL))objc_msgSend)(element, processIdentifier);
    if (pid > 0) [pids addObject:@(pid)];
  }
  return pids;
}

+ (nullable NSString *)bundleIdentifierForPID:(pid_t)pid error:(NSError **)error {
  id proxy = ISimSend([self daemonSession], @"daemonProxy");
  SEL selector = NSSelectorFromString(@"_XCT_requestBundleIDForPID:reply:");
  if (![proxy respondsToSelector:selector]) {
    if (error) *error = ISimError(@"testmanagerd cannot map processes to bundle identifiers in this Xcode");
    return nil;
  }
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  __block NSString *bundleID = nil;
  __block NSError *replyError = nil;
  ((void (*)(id, SEL, pid_t, void (^)(NSString *, NSError *)))objc_msgSend)(proxy, selector, pid, ^(NSString *identifier, NSError *failure) {
    bundleID = identifier;
    replyError = failure;
    dispatch_semaphore_signal(done);
  });
  if (!ISimWait(done, 5)) {
    if (error) *error = ISimError([NSString stringWithFormat:@"testmanagerd did not name process %d in 5 s", pid]);
    return nil;
  }
  if (bundleID == nil && error) *error = replyError ?: ISimError([NSString stringWithFormat:@"no bundle identifier for process %d", pid]);
  return bundleID;
}

+ (UIInterfaceOrientation)interfaceOrientationOfApplication:(id)application {
  SEL selector = NSSelectorFromString(@"interfaceOrientation");
  if (![application respondsToSelector:selector]) return UIInterfaceOrientationPortrait;
  UIInterfaceOrientation orientation = ((UIInterfaceOrientation (*)(id, SEL))objc_msgSend)(application, selector);
  return orientation == UIInterfaceOrientationUnknown ? UIInterfaceOrientationPortrait : orientation;
}

+ (id)pathAt:(CGPoint)point {
  id path = [NSClassFromString(@"XCPointerEventPath") alloc];
  return ((id (*)(id, SEL, CGPoint, double))objc_msgSend)(path, NSSelectorFromString(@"initForTouchAtPoint:offset:"), point, 0.0);
}

+ (void)path:(id)path liftUpAt:(NSTimeInterval)offset {
  ((void (*)(id, SEL, double))objc_msgSend)(path, NSSelectorFromString(@"liftUpAtOffset:"), offset);
}

+ (void)path:(id)path pressDownAt:(NSTimeInterval)offset {
  ((void (*)(id, SEL, double))objc_msgSend)(path, NSSelectorFromString(@"pressDownAtOffset:"), offset);
}

+ (void)path:(id)path moveTo:(CGPoint)point at:(NSTimeInterval)offset {
  ((void (*)(id, SEL, CGPoint, double))objc_msgSend)(path, NSSelectorFromString(@"moveToPoint:atOffset:"), point, offset);
}

+ (BOOL)synthesize:(id)path name:(NSString *)name orientation:(UIInterfaceOrientation)orientation
          duration:(NSTimeInterval)duration error:(NSError **)error {
  id record = [NSClassFromString(@"XCSynthesizedEventRecord") alloc];
  record = ((id (*)(id, SEL, NSString *, UIInterfaceOrientation))objc_msgSend)(
    record, NSSelectorFromString(@"initWithName:interfaceOrientation:"), name, orientation);
  ((void (*)(id, SEL, id))objc_msgSend)(record, NSSelectorFromString(@"addPointerEventPath:"), path);

  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  __block NSError *failure = nil;
  ((void (*)(id, SEL, id, void (^)(BOOL, NSError *)))objc_msgSend)(
    [self daemonSession], NSSelectorFromString(@"synthesizeEvent:completion:"), record, ^(BOOL succeeded, NSError *result) {
      failure = succeeded ? nil : (result ?: ISimError(@"testmanagerd refused the event"));
      dispatch_semaphore_signal(done);
    });
  // The completion comes once the whole gesture has been played.
  if (!ISimWait(done, duration + 10)) {
    if (error) *error = ISimError([NSString stringWithFormat:@"%@ was not confirmed by testmanagerd in time", name]);
    return NO;
  }
  if (failure) {
    if (error) *error = failure;
    return NO;
  }
  return YES;
}

+ (BOOL)tapAtPoint:(CGPoint)point count:(NSInteger)count hold:(NSTimeInterval)hold
       orientation:(UIInterfaceOrientation)orientation error:(NSError **)error {
  // Taps of a double tap come 0.1 s apart, well inside the system's double-tap interval.
  static const NSTimeInterval gap = 0.1;
  id path = [self pathAt:point];
  NSTimeInterval offset = hold;
  [self path:path liftUpAt:offset];
  for (NSInteger tap = 1; tap < count; tap++) {
    offset += gap;
    [self path:path pressDownAt:offset];
    offset += hold;
    [self path:path liftUpAt:offset];
  }
  return [self synthesize:path name:@"tap" orientation:orientation duration:offset error:error];
}

+ (BOOL)swipeFrom:(CGPoint)start to:(CGPoint)end duration:(NSTimeInterval)duration
      orientation:(UIInterfaceOrientation)orientation error:(NSError **)error {
  // A point per display frame, so scroll views see a steady finger rather than a jump.
  NSInteger steps = MAX(2, (NSInteger)ceil(duration * 60));
  id path = [self pathAt:start];
  for (NSInteger step = 1; step <= steps; step++) {
    double t = (double)step / steps;
    CGPoint point = CGPointMake(start.x + (end.x - start.x) * t, start.y + (end.y - start.y) * t);
    [self path:path moveTo:point at:duration * t];
  }
  [self path:path liftUpAt:duration];
  return [self synthesize:path name:@"swipe" orientation:orientation duration:duration error:error];
}

+ (BOOL)canPressKeys {
  Class path = NSClassFromString(@"XCPointerEventPath");
  return [self canSynthesizeEvents]
    && [path instancesRespondToSelector:NSSelectorFromString(@"initForTextInput")]
    && [path instancesRespondToSelector:NSSelectorFromString(@"typeKey:modifiers:atOffset:")];
}

+ (BOOL)pressKey:(NSString *)key modifiers:(NSUInteger)modifiers error:(NSError **)error {
  id path = ((id (*)(id, SEL))objc_msgSend)([NSClassFromString(@"XCPointerEventPath") alloc], NSSelectorFromString(@"initForTextInput"));
  ((void (*)(id, SEL, NSString *, NSUInteger, double))objc_msgSend)(path, NSSelectorFromString(@"typeKey:modifiers:atOffset:"), key, modifiers, 0.0);
  return [self synthesize:path name:@"key" orientation:UIInterfaceOrientationPortrait duration:0.1 error:error];
}

+ (BOOL)canTypeText {
  id proxy = ISimSend([self daemonSession], @"daemonProxy");
  return [proxy respondsToSelector:NSSelectorFromString(@"_XCT_sendString:maximumFrequency:completion:")];
}

+ (BOOL)typeText:(NSString *)text frequency:(NSUInteger)frequency error:(NSError **)error {
  id proxy = ISimSend([self daemonSession], @"daemonProxy");
  SEL selector = NSSelectorFromString(@"_XCT_sendString:maximumFrequency:completion:");
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  __block NSError *failure = nil;
  ((void (*)(id, SEL, NSString *, NSUInteger, void (^)(NSError *)))objc_msgSend)(proxy, selector, text, frequency, ^(NSError *result) {
    failure = result;
    dispatch_semaphore_signal(done);
  });
  if (!ISimWait(done, 10 + (double)text.length / MAX(frequency, 1))) {
    if (error) *error = ISimError(@"typing was not confirmed by testmanagerd in time");
    return NO;
  }
  if (failure) {
    if (error) *error = failure;
    return NO;
  }
  return YES;
}

+ (BOOL)snapshot:(id)snapshot boolForKey:(NSString *)key {
  SEL selector = NSSelectorFromString(key);
  if (![snapshot respondsToSelector:selector]) return NO;
  return ((BOOL (*)(id, SEL))objc_msgSend)(snapshot, selector);
}

@end
