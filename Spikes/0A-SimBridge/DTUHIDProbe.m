// Probe for the dtuhidd XPC protocol (Xcode 27 replacement for legacy Indigo buttons/keyboard).
// Usage: dtuhid-probe <udid|booted> <service> <json-message>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <xpc/xpc.h>

@interface SimDevice : NSObject
@property (readonly) NSUUID *UDID;
@property (readonly) NSString *stateString;
- (mach_port_t)lookup:(NSString *)name error:(NSError **)error;
@end
@interface SimDeviceSet : NSObject
@property (readonly) NSArray<SimDevice *> *devices;
@end
@interface SimServiceContext : NSObject
+ (instancetype)sharedServiceContextForDeveloperDir:(NSString *)dir error:(NSError **)error;
- (SimDeviceSet *)defaultDeviceSetWithError:(NSError **)error;
@end

extern xpc_endpoint_t xpc_endpoint_create_mach_port_4sim(mach_port_t port, uint64_t a, uint64_t b);
extern void xpc_connection_enable_sim2host_4sim(xpc_connection_t connection);

static xpc_object_t toXPC(id obj) {
  if ([obj isKindOfClass:NSDictionary.class]) {
    xpc_object_t d = xpc_dictionary_create(NULL, NULL, 0);
    [obj enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) { xpc_dictionary_set_value(d, k.UTF8String, toXPC(v)); }];
    return d;
  }
  if ([obj isKindOfClass:NSArray.class]) {
    xpc_object_t a = xpc_array_create(NULL, 0);
    for (id v in obj) xpc_array_append_value(a, toXPC(v));
    return a;
  }
  if ([obj isKindOfClass:NSString.class]) {
    NSString *s = obj;
    // "u:5" -> uint64, "i:-1" -> int64, "d:1.5" -> double, "b:1" -> bool, otherwise string
    if ([s hasPrefix:@"u:"]) return xpc_uint64_create(strtoull([s substringFromIndex:2].UTF8String, NULL, 0));
    if ([s hasPrefix:@"i:"]) return xpc_int64_create(strtoll([s substringFromIndex:2].UTF8String, NULL, 0));
    if ([s hasPrefix:@"d:"]) return xpc_double_create([s substringFromIndex:2].doubleValue);
    if ([s hasPrefix:@"b:"]) return xpc_bool_create([s substringFromIndex:2].boolValue);
    return xpc_string_create(s.UTF8String);
  }
  if ([obj isKindOfClass:NSNumber.class]) {
    NSNumber *n = obj;
    if (strcmp(n.objCType, @encode(BOOL)) == 0 || strcmp(n.objCType, "c") == 0) return xpc_bool_create(n.boolValue);
    if (strcmp(n.objCType, "d") == 0 || strcmp(n.objCType, "f") == 0) return xpc_double_create(n.doubleValue);
    return xpc_int64_create(n.longLongValue);
  }
  if ([obj isKindOfClass:NSNull.class]) return xpc_null_create();
  return xpc_string_create([obj description].UTF8String);
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    if (argc < 4) { fprintf(stderr, "usage: dtuhid-probe <udid|booted> <service> <json> [json...]\n"); return 2; }
    dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW);
    NSError *err = nil;
    SimServiceContext *ctx = [objc_getClass("SimServiceContext") sharedServiceContextForDeveloperDir:@"/Applications/Xcode.app/Contents/Developer" error:&err];
    SimDevice *device = nil;
    NSString *want = @(argv[1]);
    for (SimDevice *d in [ctx defaultDeviceSetWithError:&err].devices) {
      if ([want isEqualToString:@"booted"] ? [d.stateString isEqualToString:@"Booted"] : [d.UDID.UUIDString isEqualToString:want]) { device = d; break; }
    }
    if (!device) { fprintf(stderr, "device not found\n"); return 1; }
    mach_port_t port = [device lookup:@(argv[2]) error:&err];
    if (!port) { fprintf(stderr, "lookup failed: %s\n", err.description.UTF8String); return 1; }
    printf("port %u\n", port);
    xpc_connection_t conn = xpc_connection_create_from_endpoint(xpc_endpoint_create_mach_port_4sim(port, 0, 0));
    // Without this dtuhidd sees the peer but never a payload.
    xpc_connection_enable_sim2host_4sim(conn);
    xpc_connection_set_event_handler(conn, ^(xpc_object_t ev) {
      char *desc = xpc_copy_description(ev);
      printf("%.3f event: %s\n", CFAbsoluteTimeGetCurrent(), desc);
      free(desc);
    });
    xpc_connection_resume(conn);
    printf("%.3f resumed\n", CFAbsoluteTimeGetCurrent());
    for (int i = 3; i < argc; i++) {
      id json = [NSJSONSerialization JSONObjectWithData:[@(argv[i]) dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&err];
      if (!json) { fprintf(stderr, "bad json: %s\n", err.description.UTF8String); return 1; }
      xpc_object_t msg = toXPC(json);
      char *desc = xpc_copy_description(msg);
      printf("%.3f send: %s\n", CFAbsoluteTimeGetCurrent(), desc);
      free(desc);
      // Only barriers are answered; anything else is fire-and-forget.
      if (xpc_dictionary_get_bool(msg, "isBarrier")) {
        xpc_object_t reply = xpc_connection_send_message_with_reply_sync(conn, msg);
        desc = xpc_copy_description(reply);
        printf("%.3f reply: %s\n", CFAbsoluteTimeGetCurrent(), desc);
        free(desc);
        usleep(200 * 1000);
      } else {
        xpc_connection_send_message(conn, msg);
      }
    }
    // Let dtuhidd consume the events before the connection goes away.
    usleep(300 * 1000);
  }
  return 0;
}
