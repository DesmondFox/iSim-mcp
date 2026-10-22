// Spike 0A: HID input and accessibility on the iOS Simulator via private CoreSimulator/SimulatorKit APIs.
// Build: make -C Spikes/0A-SimBridge
// Usage: simbridge-spike <command> [udid] [args...]   (udid may be "booted")

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <xpc/xpc.h>

#pragma mark - Private API declarations

@interface SimDeviceType : NSObject
@property (readonly) CGSize mainScreenSize;
@property (readonly) float mainScreenScale;
@end

@interface SimDevice : NSObject
@property (readonly) NSUUID *UDID;
@property (readonly) NSString *name;
@property (readonly) NSString *stateString;
@property (readonly) unsigned long long state;
@property (readonly) SimDeviceType *deviceType;
- (void)sendAccessibilityRequestAsync:(id)request completionQueue:(dispatch_queue_t)queue completionHandler:(void (^)(id response))handler;
@end

@interface SimDeviceSet : NSObject
@property (readonly) NSArray<SimDevice *> *devices;
@end

@interface SimServiceContext : NSObject
+ (instancetype)sharedServiceContextForDeveloperDir:(NSString *)dir error:(NSError **)error;
- (SimDeviceSet *)defaultDeviceSetWithError:(NSError **)error;
@end

// Legacy Indigo (SimulatorKit). From Xcode 27 the guest drops Indigo buttons/keyboard and delivers
// touch unreliably; kept only for the `indigo-tap` comparison command.
typedef struct IndigoHIDMessageStruct IndigoHIDMessageStruct;

@interface SimDeviceLegacyHIDClient : NSObject
- (instancetype)initWithDevice:(SimDevice *)device error:(NSError **)error;
- (void)sendWithMessage:(IndigoHIDMessageStruct *)message freeWhenDone:(BOOL)free completionQueue:(dispatch_queue_t)queue completion:(void (^)(NSError *))completion;
@end

typedef IndigoHIDMessageStruct *(*IndigoMouseFn)(CGPoint *p0, CGPoint *p1, uint32_t target, NSInteger eventType, CGSize screenSize, uint32_t edge);
static const uint32_t kIndigoTargetDigitizer = 0x32;

// dtuhidd transport (Xcode 27+): plain-XPC dictionaries to a CoreDevice HID daemon inside the guest.
@interface SimDevice (Lookup)
- (mach_port_t)lookup:(NSString *)name error:(NSError **)error;
@end

typedef xpc_endpoint_t (*XPCEndpointFromPortFn)(mach_port_t port, uint64_t, uint64_t);
typedef void (*XPCEnableSim2HostFn)(xpc_connection_t connection);

static NSString *const kDigitizerService = @"com.apple.coredevice.feature.remote.hid.digitizer";

// HIDButtonState is 1-based on the wire.
static const uint64_t kStateDown = 1;
static const uint64_t kStateUp = 2;

// IndigoDigitizerEvent per-contact phase.
static const uint64_t kTouchStart = 0;
static const uint64_t kTouchPosition = 1;
static const uint64_t kTouchEnd = 2;

@interface AXPTranslationObject : NSObject <NSCopying>
@property (copy) NSString *bridgeDelegateToken;
@property int pid;
@end

@interface AXPTranslator : NSObject
+ (instancetype)sharedInstance;
@property (weak) id bridgeTokenDelegate;
@property BOOL supportsDelegateTokens;
@property BOOL accessibilityEnabled;
- (AXPTranslationObject *)frontmostApplicationWithDisplayId:(unsigned)displayId bridgeDelegateToken:(NSString *)token;
- (AXPTranslationObject *)objectAtPoint:(CGPoint)point displayId:(unsigned)displayId bridgeDelegateToken:(NSString *)token;
- (NSAccessibilityElement *)macPlatformElementFromTranslation:(AXPTranslationObject *)translation;
@end

// AXPMacPlatformElement is an NSAccessibilityElement subclass that also exposes its translation.
@interface NSAccessibilityElement (AXPMacPlatformElement)
@property (readonly) AXPTranslationObject *translation;
@end

#pragma mark - Helpers

static void die(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void die(NSString *fmt, ...) {
  va_list ap; va_start(ap, fmt);
  NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  fprintf(stderr, "error: %s\n", s.UTF8String);
  exit(1);
}

static void *loadFramework(NSString *path) {
  void *h = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
  if (!h) die(@"dlopen %@: %s", path, dlerror());
  return h;
}

static NSString *developerDir(void) {
  NSString *env = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
  if (env.length) return env;
  NSTask *t = [NSTask new];
  t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcode-select"];
  t.arguments = @[@"-p"];
  NSPipe *p = [NSPipe pipe];
  t.standardOutput = p;
  [t launchAndReturnError:nil];
  [t waitUntilExit];
  NSData *d = [p.fileHandleForReading readDataToEndOfFile];
  return [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static SimDeviceSet *deviceSet(void) {
  NSString *dev = developerDir();
  loadFramework(@"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator");
  NSError *err = nil;
  SimServiceContext *ctx = [objc_getClass("SimServiceContext") sharedServiceContextForDeveloperDir:dev error:&err];
  if (!ctx) die(@"SimServiceContext: %@", err);
  SimDeviceSet *set = [ctx defaultDeviceSetWithError:&err];
  if (!set) die(@"defaultDeviceSet: %@", err);
  return set;
}

static SimDevice *findDevice(NSString *udid) {
  NSArray<SimDevice *> *devices = deviceSet().devices;
  for (SimDevice *d in devices) {
    if ([udid isEqualToString:@"booted"] ? [d.stateString isEqualToString:@"Booted"] : [d.UDID.UUIDString caseInsensitiveCompare:udid] == NSOrderedSame) return d;
  }
  die(@"device %@ not found", udid);
  return nil;
}

static CGSize screenSizePoints(SimDevice *d) {
  CGSize px = d.deviceType.mainScreenSize;
  float scale = d.deviceType.mainScreenScale;
  return CGSizeMake(px.width / scale, px.height / scale);
}

#pragma mark - dtuhidd transport

@interface DTUHIDConnection : NSObject
@property (readonly) xpc_connection_t connection;
@property (readonly) CGSize screen;
@end

@implementation DTUHIDConnection

- (instancetype)initWithDevice:(SimDevice *)device {
  if (!(self = [super init])) return nil;
  XPCEndpointFromPortFn endpointFromPort = (XPCEndpointFromPortFn)dlsym(RTLD_DEFAULT, "xpc_endpoint_create_mach_port_4sim");
  XPCEnableSim2HostFn enableSim2Host = (XPCEnableSim2HostFn)dlsym(RTLD_DEFAULT, "xpc_connection_enable_sim2host_4sim");
  if (!endpointFromPort || !enableSim2Host) die(@"libxpc _4sim symbols missing");
  NSError *err = nil;
  mach_port_t port = [device lookup:kDigitizerService error:&err];
  if (port == MACH_PORT_NULL) die(@"lookup %@: %@", kDigitizerService, err);
  // The endpoint consumes the lookup's send right.
  _connection = xpc_connection_create_from_endpoint(endpointFromPort(port, 0, 0));
  // Without this the daemon sees the peer but never a payload.
  enableSim2Host(_connection);
  xpc_connection_set_event_handler(_connection, ^(xpc_object_t event) {
    if (event == XPC_ERROR_CONNECTION_INTERRUPTED) fprintf(stderr, "warning: dtuhidd connection interrupted\n");
  });
  xpc_connection_resume(_connection);
  _screen = screenSizePoints(device);
  [self confirmLiveness];
  return self;
}

- (xpc_object_t)messageOfType:(NSString *)type barrier:(BOOL)barrier payload:(xpc_object_t)payload {
  xpc_object_t msg = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_string(msg, "messageType", type.UTF8String);
  xpc_dictionary_set_bool(msg, "isBarrier", barrier);
  xpc_dictionary_set_string(msg, "featureIdentifier", kDigitizerService.UTF8String);
  xpc_dictionary_set_value(msg, "payload", payload);
  return msg;
}

// The daemon is demand-launched and drops events that arrive before the peer is activated. A barrier
// is the only message it answers, so a reply proves it is alive and ready.
- (void)confirmLiveness {
  xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_uint64(payload, "usageCode", 0);
  xpc_dictionary_set_uint64(payload, "state", kStateUp);
  NSDate *start = NSDate.date;
  xpc_object_t reply = xpc_connection_send_message_with_reply_sync(_connection, [self messageOfType:@"IndigoKeyboardButtonEvent" barrier:YES payload:payload]);
  if (xpc_get_type(reply) == XPC_TYPE_ERROR) die(@"dtuhidd did not answer the barrier: %s", xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION));
  fprintf(stderr, "dtuhidd ready in %.0f ms\n", -start.timeIntervalSinceNow * 1000);
  // Device-open tail after peer activation.
  usleep(200 * 1000);
}

- (void)send:(NSString *)type payload:(xpc_object_t)payload {
  xpc_connection_send_message(_connection, [self messageOfType:type barrier:NO payload:payload]);
}

- (void)touch:(CGPoint)p phase:(uint64_t)phase {
  xpc_object_t point = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_double(point, "x", p.x / _screen.width);
  xpc_dictionary_set_double(point, "y", p.y / _screen.height);
  xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_value(payload, "pointOne", point);
  xpc_dictionary_set_uint64(payload, "eventType", phase);
  xpc_dictionary_set_uint64(payload, "edge", 0);
  xpc_dictionary_set_uint64(payload, "target", 0);
  [self send:@"IndigoDigitizerEvent" payload:payload];
}

- (void)button:(uint64_t)usage state:(uint64_t)state {
  xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_uint64(payload, "usagePage", 0x0C);
  xpc_dictionary_set_uint64(payload, "usageCode", usage);
  xpc_dictionary_set_uint64(payload, "state", state);
  [self send:@"IndigoButtonEvent" payload:payload];
}

- (void)key:(uint64_t)usage state:(uint64_t)state {
  xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_uint64(payload, "usageCode", usage);
  xpc_dictionary_set_uint64(payload, "state", state);
  [self send:@"IndigoKeyboardButtonEvent" payload:payload];
}

// Lets the daemon consume queued events before the process exits and the connection dies.
- (void)drain {
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  xpc_connection_send_barrier(_connection, ^{ dispatch_semaphore_signal(sem); });
  dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
  usleep(80 * 1000);
}

@end

#pragma mark - Commands

static void cmdList(void) {
  for (SimDevice *d in deviceSet().devices) {
    CGSize pt = screenSizePoints(d);
    printf("%s  %-10s %-28s %.0fx%.0f pt @%.0fx\n", d.UDID.UUIDString.UTF8String, d.stateString.UTF8String, d.name.UTF8String, pt.width, pt.height, d.deviceType.mainScreenScale);
  }
}

static void cmdTap(SimDevice *d, double x, double y, int count, int holdMs) {
  DTUHIDConnection *c = [[DTUHIDConnection alloc] initWithDevice:d];
  CGPoint p = CGPointMake(x, y);
  for (int i = 0; i < count; i++) {
    [c touch:p phase:kTouchStart];
    usleep(holdMs * 1000);
    [c touch:p phase:kTouchEnd];
    if (i + 1 < count) usleep(80 * 1000);
  }
  [c drain];
}

static void cmdSwipe(SimDevice *d, CGPoint from, CGPoint to, int durationMs) {
  DTUHIDConnection *c = [[DTUHIDConnection alloc] initWithDevice:d];
  int steps = MAX(2, durationMs / 16);
  [c touch:from phase:kTouchStart];
  for (int i = 1; i <= steps; i++) {
    double t = (double)i / steps;
    usleep(durationMs * 1000 / steps);
    [c touch:CGPointMake(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t) phase:kTouchPosition];
  }
  [c touch:to phase:kTouchEnd];
  [c drain];
}

static void cmdButton(SimDevice *d, NSString *name, int holdMs) {
  // HID Consumer page (0x0C) usages.
  NSDictionary<NSString *, NSNumber *> *map = @{@"home": @0x40, @"lock": @0x30, @"side": @0x95, @"siri": @0xCF, @"volume_up": @0xE9, @"volume_down": @0xEA};
  NSNumber *usage = map[name];
  if (!usage) die(@"unknown button %@ (%@)", name, [map.allKeys componentsJoinedByString:@", "]);
  DTUHIDConnection *c = [[DTUHIDConnection alloc] initWithDevice:d];
  [c button:usage.unsignedLongLongValue state:kStateDown];
  usleep(holdMs * 1000);
  [c button:usage.unsignedLongLongValue state:kStateUp];
  [c drain];
}

// US layout: character -> (HID usage, needs shift).
static BOOL usageForChar(unichar ch, uint32_t *usage, BOOL *shift) {
  *shift = NO;
  if (ch >= 'a' && ch <= 'z') { *usage = 0x04 + (ch - 'a'); return YES; }
  if (ch >= 'A' && ch <= 'Z') { *usage = 0x04 + (ch - 'A'); *shift = YES; return YES; }
  if (ch >= '1' && ch <= '9') { *usage = 0x1e + (ch - '1'); return YES; }
  if (ch == '0') { *usage = 0x27; return YES; }
  const char *plain = " -=[]\\;'`,./\n\t";
  const uint32_t plainUsage[] = {0x2c, 0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x28, 0x2b};
  const char *shifted = "!@#$%^&*()_+{}|:\"~<>?";
  const uint32_t shiftedUsage[] = {0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38};
  for (int i = 0; plain[i]; i++) if (plain[i] == ch) { *usage = plainUsage[i]; return YES; }
  for (int i = 0; shifted[i]; i++) if (shifted[i] == ch) { *usage = shiftedUsage[i]; *shift = YES; return YES; }
  return NO;
}

static void cmdType(SimDevice *d, NSString *text) {
  const uint32_t leftShift = 0xe1;
  for (NSUInteger i = 0; i < text.length; i++) {
    uint32_t usage; BOOL shift;
    if (!usageForChar([text characterAtIndex:i], &usage, &shift)) die(@"character %C is not on the US layout", [text characterAtIndex:i]);
  }
  DTUHIDConnection *c = [[DTUHIDConnection alloc] initWithDevice:d];
  for (NSUInteger i = 0; i < text.length; i++) {
    uint32_t usage; BOOL shift;
    usageForChar([text characterAtIndex:i], &usage, &shift);
    if (shift) [c key:leftShift state:kStateDown];
    [c key:usage state:kStateDown];
    [c key:usage state:kStateUp];
    if (shift) [c key:leftShift state:kStateUp];
  }
  [c drain];
}

// Modifiers are HID usages too (0xe0..0xe7), e.g. `key booted 0x04 0xe3` is Cmd+A.
static void cmdKey(SimDevice *d, uint32_t usage, NSArray<NSNumber *> *modifiers) {
  DTUHIDConnection *c = [[DTUHIDConnection alloc] initWithDevice:d];
  for (NSNumber *m in modifiers) [c key:m.unsignedLongLongValue state:kStateDown];
  [c key:usage state:kStateDown];
  [c key:usage state:kStateUp];
  for (NSNumber *m in modifiers.reverseObjectEnumerator) [c key:m.unsignedLongLongValue state:kStateUp];
  [c drain];
}

// Legacy Indigo tap, for comparison with the dtuhidd path.
static void cmdIndigoTap(SimDevice *d, double x, double y) {
  NSString *path = [developerDir() stringByAppendingPathComponent:@"../SharedFrameworks/SimulatorKit.framework/SimulatorKit"];
  IndigoMouseFn mouse = (IndigoMouseFn)dlsym(loadFramework(path.stringByStandardizingPath), "IndigoHIDMessageForMouseNSEvent");
  if (!mouse) die(@"IndigoHIDMessageForMouseNSEvent missing");
  NSError *err = nil;
  SimDeviceLegacyHIDClient *client = [[objc_getClass("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") alloc] initWithDevice:d error:&err];
  if (!client) die(@"HID client: %@", err);
  CGSize screen = screenSizePoints(d);
  CGPoint p = CGPointMake(x, y);
  for (NSNumber *type in @[@(NSEventTypeLeftMouseDown), @(NSEventTypeLeftMouseUp)]) {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [client sendWithMessage:mouse(&p, NULL, kIndigoTargetDigitizer, type.integerValue, screen, 0) freeWhenDone:YES completionQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0) completion:^(NSError *e) {
      if (e) fprintf(stderr, "send: %s\n", e.description.UTF8String);
      dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    usleep(60 * 1000);
  }
}

#pragma mark - Accessibility

// Bridges AXPTranslator requests to the simulator over CoreSimulator's accessibility channel.
@interface SpikeAXBridge : NSObject
@property (strong) SimDevice *device;
@end

@implementation SpikeAXBridge

- (id)accessibilityTranslationDelegateBridgeCallbackWithToken:(NSString *)token {
  SimDevice *device = self.device;
  return ^id(id request) {
    __block id response = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [device sendAccessibilityRequestAsync:request completionQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0) completionHandler:^(id r) {
      response = r;
      dispatch_semaphore_signal(sem);
    }];
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) {
      fprintf(stderr, "warning: accessibility request timed out\n");
      return ((id (*)(id, SEL))objc_msgSend)(objc_getClass("AXPTranslatorResponse"), sel_registerName("emptyResponse"));
    }
    return response;
  };
}

- (CGRect)accessibilityTranslationConvertPlatformFrameToSystem:(CGRect)rect withToken:(NSString *)token {
  return rect;
}

- (id)accessibilityTranslationRootParentWithToken:(NSString *)token {
  return nil;
}

@end

static AXPTranslator *axTranslator(SimDevice *device, SpikeAXBridge *bridge) {
  loadFramework(@"/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation");
  bridge.device = device;
  AXPTranslator *t = [objc_getClass("AXPTranslator") sharedInstance];
  t.bridgeTokenDelegate = bridge;
  t.supportsDelegateTokens = YES;
  t.accessibilityEnabled = YES;
  return t;
}

static NSString *axString(id v) {
  if (!v) return nil;
  NSString *s = [v isKindOfClass:NSAttributedString.class] ? [v string] : [v description];
  return s.length ? s : nil;
}

static void printElement(NSAccessibilityElement *e, NSString *token, int depth, int maxDepth) {
  e.translation.bridgeDelegateToken = token;
  NSString *role = axString(e.accessibilityRole) ?: @"?";
  if ([role hasPrefix:@"AX"]) role = [role substringFromIndex:2];
  NSMutableString *line = [NSMutableString stringWithFormat:@"%*s[%@]", depth * 2, "", role];
  NSString *subrole = axString(e.accessibilitySubrole);
  if (subrole) [line appendFormat:@"/%@", [subrole hasPrefix:@"AX"] ? [subrole substringFromIndex:2] : subrole];
  NSString *label = axString(e.accessibilityLabel);
  if (label) [line appendFormat:@" \"%@\"", label];
  NSString *ident = axString(e.accessibilityIdentifier);
  if (ident) [line appendFormat:@" id=%@", ident];
  NSString *value = axString(e.accessibilityValue);
  if (value) [line appendFormat:@" value=\"%@\"", value];
  CGRect f = e.accessibilityFrame;
  [line appendFormat:@" (%.0f,%.0f %.0f×%.0f)", f.origin.x, f.origin.y, f.size.width, f.size.height];
  printf("%s\n", line.UTF8String);
  if (depth >= maxDepth) return;
  for (NSAccessibilityElement *child in e.accessibilityChildren) printElement(child, token, depth + 1, maxDepth);
}

static void cmdDescribeUI(SimDevice *d, int maxDepth) {
  SpikeAXBridge *bridge = [SpikeAXBridge new];
  AXPTranslator *t = axTranslator(d, bridge);
  NSString *token = NSUUID.UUID.UUIDString;
  NSDate *start = NSDate.date;
  AXPTranslationObject *app = [t frontmostApplicationWithDisplayId:0 bridgeDelegateToken:token];
  if (!app) die(@"no frontmost application translation");
  app.bridgeDelegateToken = token;
  NSAccessibilityElement *root = [t macPlatformElementFromTranslation:app];
  printElement(root, token, 0, maxDepth);
  fprintf(stderr, "pid=%d, %.0f ms\n", app.pid, -start.timeIntervalSinceNow * 1000);
}

static void cmdDescribePoint(SimDevice *d, double x, double y) {
  SpikeAXBridge *bridge = [SpikeAXBridge new];
  AXPTranslator *t = axTranslator(d, bridge);
  NSString *token = NSUUID.UUID.UUIDString;
  AXPTranslationObject *obj = [t objectAtPoint:CGPointMake(x, y) displayId:0 bridgeDelegateToken:token];
  if (!obj) die(@"nothing at %.0f,%.0f", x, y);
  obj.bridgeDelegateToken = token;
  printElement([t macPlatformElementFromTranslation:obj], token, 0, 0);
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    NSMutableArray<NSString *> *a = [NSMutableArray array];
    for (int i = 1; i < argc; i++) [a addObject:@(argv[i])];
    if (a.count == 0) die(@"usage: simbridge-spike list | tap <udid> x y [count] [hold_ms] | swipe <udid> x1 y1 x2 y2 [ms] | button <udid> home|lock|side|siri|volume_up|volume_down [hold_ms] | type <udid> text | key <udid> usage [modifier...] | indigo-tap <udid> x y | ui <udid> [max_depth] | point <udid> x y");
    NSString *cmd = a[0];
    if ([cmd isEqualToString:@"list"]) { cmdList(); return 0; }
    if (a.count < 2) die(@"%@ needs a udid", cmd);
    SimDevice *d = findDevice(a[1]);
    if (![d.stateString isEqualToString:@"Booted"]) die(@"device %@ is %@", d.name, d.stateString);
    if ([cmd isEqualToString:@"tap"] && a.count >= 4) cmdTap(d, a[2].doubleValue, a[3].doubleValue, a.count > 4 ? a[4].intValue : 1, a.count > 5 ? a[5].intValue : 60);
    else if ([cmd isEqualToString:@"swipe"] && a.count >= 6) cmdSwipe(d, CGPointMake(a[2].doubleValue, a[3].doubleValue), CGPointMake(a[4].doubleValue, a[5].doubleValue), a.count > 6 ? a[6].intValue : 300);
    else if ([cmd isEqualToString:@"button"] && a.count >= 3) cmdButton(d, a[2], a.count > 3 ? a[3].intValue : 100);
    else if ([cmd isEqualToString:@"type"] && a.count >= 3) cmdType(d, a[2]);
    else if ([cmd isEqualToString:@"key"] && a.count >= 3) {
      NSMutableArray<NSNumber *> *mods = [NSMutableArray array];
      for (NSUInteger i = 3; i < a.count; i++) [mods addObject:@(strtoul(a[i].UTF8String, NULL, 0))];
      cmdKey(d, (uint32_t)strtoul(a[2].UTF8String, NULL, 0), mods);
    }
    else if ([cmd isEqualToString:@"indigo-tap"] && a.count >= 4) cmdIndigoTap(d, a[2].doubleValue, a[3].doubleValue);
    else if ([cmd isEqualToString:@"ui"]) cmdDescribeUI(d, a.count > 2 ? a[2].intValue : 50);
    else if ([cmd isEqualToString:@"point"] && a.count >= 4) cmdDescribePoint(d, a[2].doubleValue, a[3].doubleValue);
    else die(@"bad arguments for %@", cmd);
  }
  return 0;
}
