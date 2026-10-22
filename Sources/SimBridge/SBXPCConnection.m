#import <dlfcn.h>
#import <stdatomic.h>

#import "SBPrivate.h"

// libxpc's simulator bridge. The endpoint consumes the send right from -[SimDevice lookup:error:].
typedef xpc_endpoint_t (*SBEndpointFromPortFn)(mach_port_t port, uint64_t, uint64_t);
typedef void (*SBEnableSim2HostFn)(xpc_connection_t connection);

@implementation SBXPCConnection {
    xpc_connection_t _connection;
    dispatch_queue_t _queue;
    _Atomic(NSUInteger) _interruptions;
    _Atomic(BOOL) _invalidated;
    _Atomic(BOOL) _cancelled;
}

- (instancetype)initWithSimulator:(SBSimulator *)simulator service:(NSString *)service error:(NSError **)error {
    static SBEndpointFromPortFn endpointFromPort;
    static SBEnableSim2HostFn enableSim2Host;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        endpointFromPort = (SBEndpointFromPortFn)dlsym(RTLD_DEFAULT, "xpc_endpoint_create_mach_port_4sim");
        enableSim2Host = (SBEnableSim2HostFn)dlsym(RTLD_DEFAULT, "xpc_connection_enable_sim2host_4sim");
    });
    if (!endpointFromPort || !enableSim2Host) {
        if (error) *error = SBMakeError(SBErrorUnavailable, @"libxpc has no simulator bridge (xpc_*_4sim); this macOS is not supported.");
        return nil;
    }
    if (!simulator.isBooted) {
        if (error) *error = SBMakeError(SBErrorNotBooted, [NSString stringWithFormat:@"Simulator %@ is not booted.", simulator.udid]);
        return nil;
    }
    if (![simulator.device respondsToSelector:@selector(lookup:error:)]) {
        if (error) *error = SBMakeError(SBErrorUnavailable, @"SimDevice has no lookup:error:; this Xcode is not supported.");
        return nil;
    }
    NSError *lookupError = nil;
    mach_port_t port = [simulator.device lookup:service error:&lookupError];
    if (port == MACH_PORT_NULL) {
        if (error) {
            *error = SBMakeError(SBErrorLookupFailed, [NSString stringWithFormat:@"The simulator has no service %@: %@", service,
                                                                                  lookupError.localizedDescription ?: @"lookup failed"]);
        }
        return nil;
    }

    if ((self = [super init])) {
        _queue = dispatch_queue_create("isim.simbridge.xpc", DISPATCH_QUEUE_SERIAL);
        _connection = xpc_connection_create_from_endpoint(endpointFromPort(port, 0, 0));
        xpc_connection_set_target_queue(_connection, _queue);
        // Without this the daemon sees the peer but never a payload.
        enableSim2Host(_connection);
        __weak SBXPCConnection *weakSelf = self;
        xpc_connection_set_event_handler(_connection, ^(xpc_object_t event) {
            SBXPCConnection *strongSelf = weakSelf;
            if (!strongSelf) return;
            if (event == XPC_ERROR_CONNECTION_INTERRUPTED) {
                atomic_fetch_add(&strongSelf->_interruptions, 1);
            } else if (event == XPC_ERROR_CONNECTION_INVALID) {
                atomic_store(&strongSelf->_invalidated, YES);
            }
        });
        xpc_connection_resume(_connection);
    }
    return self;
}

- (void)dealloc {
    [self cancel];
}

- (NSUInteger)interruptions {
    return atomic_load(&_interruptions);
}

- (BOOL)isInvalidated {
    return atomic_load(&_invalidated);
}

- (void)sendMessage:(xpc_object_t)message {
    xpc_connection_send_message(_connection, message);
}

- (void)sendMessage:(xpc_object_t)message timeout:(NSTimeInterval)timeout completion:(void (^)(xpc_object_t _Nullable))completion {
    // Both blocks run on _queue, so the flag needs no lock.
    __block BOOL finished = NO;
    xpc_connection_send_message_with_reply(_connection, message, _queue, ^(xpc_object_t reply) {
        if (finished) return;
        finished = YES;
        completion(reply);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), _queue, ^{
        if (finished) return;
        finished = YES;
        completion(nil);
    });
}

- (void)flushWithCompletion:(void (^)(void))completion {
    xpc_connection_send_barrier(_connection, completion);
}

- (void)cancel {
    atomic_store(&_invalidated, YES);
    if (!atomic_exchange(&_cancelled, YES)) xpc_connection_cancel(_connection);
}

@end
