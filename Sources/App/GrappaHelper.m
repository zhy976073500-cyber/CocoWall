/* See GrappaHelper.h. Own implementation: every private symbol is
 * resolved at runtime and checked before use; any miss is reported
 * verbatim into err_buf and surfaced as a non-zero return, so the
 * Rust core can continue the sync without a Grappa token and log
 * exactly why. */

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

static void cw_set_error(char *err_buf, size_t err_len, NSString *message) {
    if (err_buf == NULL || err_len == 0) {
        return;
    }
    const char *utf8 = message.UTF8String ?: "unknown error";
    strncpy(err_buf, utf8, err_len - 1);
    err_buf[err_len - 1] = '\0';
}

static BOOL cw_load_framework(NSString *path) {
    if (NSClassFromString(@"ATGrappaSession") != Nil) {
        return YES;
    }
    void *handle = dlopen(path.UTF8String, RTLD_NOW);
    return handle != NULL;
}

__attribute__((used))
int ALGetGrappaToken(uint32_t version,
                     uint32_t device_type,
                     uint32_t protocol_version,
                     uint8_t *out_buf,
                     size_t max_len,
                     size_t *out_len,
                     char *err_buf,
                     size_t err_len) {
    if (out_buf == NULL || out_len == NULL) {
        cw_set_error(err_buf, err_len, @"ALGetGrappaToken: null output buffer");
        return -1;
    }
    *out_len = 0;

    @autoreleasepool {
        /* The session class lives in AirTrafficHost on desktop-class
         * stacks and in AirTrafficDevice on the device; try both. */
        cw_load_framework(@"/System/Library/PrivateFrameworks/AirTrafficDevice.framework/AirTrafficDevice");
        cw_load_framework(@"/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost");

        Class sessionClass = NSClassFromString(@"ATGrappaSession");
        if (sessionClass == Nil) {
            cw_set_error(err_buf, err_len,
                         @"ATGrappaSession class not found (AirTraffic frameworks unavailable)");
            return 1;
        }

        /* Protocol parameters, carried by ATGrappaDeviceInfo when the
         * class exists, set via KVC so no private header is needed. */
        id deviceInfo = nil;
        Class infoClass = NSClassFromString(@"ATGrappaDeviceInfo");
        if (infoClass != Nil) {
            @try {
                deviceInfo = [[infoClass alloc] init];
                [deviceInfo setValue:@(version) forKey:@"version"];
                [deviceInfo setValue:@(device_type) forKey:@"deviceType"];
                [deviceInfo setValue:@(protocol_version) forKey:@"protocolVersion"];
            } @catch (NSException *e) {
                deviceInfo = nil;
                cw_set_error(err_buf, err_len,
                             [NSString stringWithFormat:@"ATGrappaDeviceInfo KVC failed: %@", e.reason ?: @""]);
                return 2;
            }
        }

        /* Obtain a session. Several factory shapes exist across OS
         * releases; probe them in order and keep the first that
         * answers. */
        id session = nil;
        SEL factorySelectors[] = {
            @selector(sessionWithDeviceInfo:),
            @selector(grappaSessionWithDeviceInfo:),
            @selector(sessionForDeviceInfo:),
        };
        for (unsigned i = 0; i < sizeof(factorySelectors) / sizeof(factorySelectors[0]) && session == nil; i++) {
            SEL sel = factorySelectors[i];
            if ([sessionClass respondsToSelector:sel]) {
                @try {
                    session = ((id (*)(id, SEL, id))objc_msgSend)(sessionClass, sel, deviceInfo);
                } @catch (NSException *e) {
                    session = nil;
                }
            }
        }
        if (session == nil && [sessionClass instancesRespondToSelector:@selector(initWithDeviceInfo:)]) {
            @try {
                id alloced = ((id (*)(id, SEL))objc_msgSend)(sessionClass, @selector(alloc));
                session = ((id (*)(id, SEL, id))objc_msgSend)(
                    alloced, @selector(initWithDeviceInfo:), deviceInfo);
            } @catch (NSException *e) {
                session = nil;
            }
        }
        if (session == nil) {
            cw_set_error(err_buf, err_len,
                         @"ATGrappaSession: no known factory selector answered");
            return 3;
        }

        /* Ask the session for the token data. */
        NSData *token = nil;
        if ([session respondsToSelector:@selector(grappaDataForSessionInfo:)]) {
            @try {
                token = ((NSData * (*)(id, SEL, id))objc_msgSend)(
                    session, @selector(grappaDataForSessionInfo:), deviceInfo);
            } @catch (NSException *e) {
                token = nil;
            }
        }
        if (token == nil && [session respondsToSelector:@selector(grappaData)]) {
            @try {
                token = ((NSData * (*)(id, SEL))objc_msgSend)(
                    session, @selector(grappaData));
            } @catch (NSException *e) {
                token = nil;
            }
        }
        if (token == nil || token.length == 0) {
            cw_set_error(err_buf, err_len,
                         @"ATGrappaSession produced no token data");
            return 4;
        }
        if (token.length > max_len) {
            cw_set_error(err_buf, err_len,
                         [NSString stringWithFormat:@"Grappa token too large (%lu bytes)",
                                                    (unsigned long)token.length]);
            return 5;
        }
        memcpy(out_buf, token.bytes, token.length);
        *out_len = token.length;
        return 0;
    }
}
