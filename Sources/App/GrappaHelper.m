/* See GrappaHelper.h. Own implementation.
 *
 * How the token is produced at runtime on this device (protocol facts
 * recorded in research/ from the reference sync hosts):
 *
 *   1. dlopen the device's AirTraffic frameworks — AirTrafficDevice
 *      first, AirTrafficHost second — logging each attempt and the raw
 *      dlerror() on failure.
 *   2. If the loaded framework itself exports a C function named
 *      ALGetGrappaToken, call it with the daemon-supplied
 *      (version, deviceType, protocolVersion) triple; that is the
 *      entry the reference hosts resolve from AirTrafficHost.
 *   3. Otherwise drive the framework's ATGrappaSession class: build
 *      the device-info dictionary (from the framework's exported
 *      ATGrappaDeviceInfo() when the daemon reported deviceType 0,
 *      otherwise from the daemon-supplied triple), open a host-type
 *      session (-initWithType: 1) and have it establish a host session
 *      (-establishHostSessionWithDeviceInfo:clientRequestData:); the
 *      returned client request data is the Grappa token.
 *
 * Every probe and result is appended to a diagnostic trace that is
 * handed back to the caller in diag_buf, so a failure on device names
 * the exact step, selector, class or NSError that stopped it. There
 * is deliberately no fallback to pre-generated token values.
 */

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdarg.h>
#import <string.h>

/* Signature shared by this helper and the framework-exported entry of
 * the same name. */
typedef int (*CWGrappaTokenFn)(uint32_t, uint32_t, uint32_t,
                               uint8_t *, size_t, size_t *,
                               char *, size_t);
/* The frameworks export a no-argument function returning the device
 * info dictionary used for Grappa sessions. */
typedef id (*CWGrappaDeviceInfoFn)(void);

static void cw_trace(NSMutableString *trace, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *step = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (trace.length > 0) {
        [trace appendString:@" | "];
    }
    [trace appendString:step ?: @"?"];
}

static void cw_finish(char *diag_buf, size_t diag_len, NSMutableString *trace) {
    if (diag_buf == NULL || diag_len == 0) {
        return;
    }
    const char *utf8 = trace.UTF8String ?: "no trace";
    strncpy(diag_buf, utf8, diag_len - 1);
    diag_buf[diag_len - 1] = '\0';
}

__attribute__((visibility("default"), used))
int ALGetGrappaToken(uint32_t version,
                     uint32_t device_type,
                     uint32_t protocol_version,
                     uint8_t *out_buf,
                     size_t max_len,
                     size_t *out_len,
                     char *diag_buf,
                     size_t diag_len) {
    if (out_buf == NULL || out_len == NULL || max_len == 0) {
        if (diag_buf != NULL && diag_len > 0) {
            strncpy(diag_buf, "invalid arguments (null output buffer)", diag_len - 1);
            diag_buf[diag_len - 1] = '\0';
        }
        return 1;
    }
    *out_len = 0;

    NSMutableString *trace = [NSMutableString string];
    int result = 0;

    @autoreleasepool {
        @try {
            /* ── Step 1: load an AirTraffic framework ───────────────── */
            void *handle = NULL;
            const char *paths[] = {
                "/System/Library/PrivateFrameworks/AirTrafficDevice.framework/AirTrafficDevice",
                "/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost",
            };
            for (unsigned i = 0; i < sizeof(paths) / sizeof(paths[0]) && handle == NULL; i++) {
                dlerror(); /* clear */
                handle = dlopen(paths[i], RTLD_NOW);
                if (handle != NULL) {
                    cw_trace(trace, @"dlopen %s -> OK", paths[i]);
                } else {
                    const char *err = dlerror();
                    cw_trace(trace, @"dlopen %s -> FAIL (%s)", paths[i], err ?: "unknown");
                }
            }
            if (handle == NULL) {
                cw_trace(trace, @"both AirTraffic frameworks failed to load");
                result = 2;
                goto done;
            }

            /* ── Step 2: the framework's own ALGetGrappaToken ───────── */
            {
                dlerror(); /* clear */
                void *fwSym = dlsym(handle, "ALGetGrappaToken");
                if (fwSym != NULL) {
                    cw_trace(trace, @"framework symbol ALGetGrappaToken -> FOUND, calling it");
                    uint8_t fwBuf[512];
                    size_t fwLen = 0;
                    char fwDiag[256] = {0};
                    int fwRc = ((CWGrappaTokenFn)fwSym)(version, device_type, protocol_version,
                                                        fwBuf, sizeof(fwBuf), &fwLen,
                                                        fwDiag, sizeof(fwDiag));
                    cw_trace(trace, @"framework ALGetGrappaToken rc=%d len=%lu diag=%s",
                             fwRc, (unsigned long)fwLen, fwDiag);
                    if (fwRc == 0 && fwLen > 0) {
                        if (fwLen > max_len) {
                            cw_trace(trace, @"token too large (%lu bytes)", (unsigned long)fwLen);
                            result = 7;
                            goto done;
                        }
                        memcpy(out_buf, fwBuf, fwLen);
                        *out_len = fwLen;
                        cw_trace(trace, @"token obtained via framework ALGetGrappaToken (%lu bytes)",
                                 (unsigned long)fwLen);
                        result = 0;
                        goto done;
                    }
                    cw_trace(trace, @"framework entry produced no token; trying ATGrappaSession");
                } else {
                    const char *err = dlerror();
                    cw_trace(trace, @"framework symbol ALGetGrappaToken -> NOT FOUND (%s); trying ATGrappaSession",
                             err ?: "no dlerror");
                }
            }

            /* ── Step 3: device info dictionary ─────────────────────── */
            NSDictionary *info = nil;
            if (device_type != 0) {
                info = @{
                    @"version" : @(version != 0 ? version : 1),
                    @"deviceType" : @(device_type),
                    @"protocolVersion" : @(protocol_version != 0 ? protocol_version : 1),
                };
                cw_trace(trace, @"device info from daemon triple: version=%@ deviceType=%@ protocolVersion=%@",
                         info[@"version"], info[@"deviceType"], info[@"protocolVersion"]);
            } else {
                CWGrappaDeviceInfoFn infoFn =
                    (CWGrappaDeviceInfoFn)dlsym(handle, "ATGrappaDeviceInfo");
                if (infoFn != NULL) {
                    cw_trace(trace, @"framework symbol ATGrappaDeviceInfo -> FOUND, calling it");
                    id produced = infoFn();
                    if ([produced isKindOfClass:[NSDictionary class]]) {
                        info = (NSDictionary *)produced;
                        cw_trace(trace, @"ATGrappaDeviceInfo returned: version=%@ deviceType=%@ protocolVersion=%@",
                                 info[@"version"], info[@"deviceType"], info[@"protocolVersion"]);
                    } else {
                        cw_trace(trace, @"ATGrappaDeviceInfo returned non-dictionary (%@); using defaults",
                                 produced ? NSStringFromClass([produced class]) : @"nil");
                    }
                } else {
                    cw_trace(trace, @"framework symbol ATGrappaDeviceInfo -> NOT FOUND; using defaults");
                }
                if (info == nil) {
                    info = @{
                        @"version" : @(version != 0 ? version : 1),
                        @"deviceType" : @0,
                        @"protocolVersion" : @(protocol_version != 0 ? protocol_version : 1),
                    };
                    cw_trace(trace, @"device info defaults: version=%@ deviceType=0 protocolVersion=%@",
                             info[@"version"], info[@"protocolVersion"]);
                }
            }

            /* ── Step 4: ATGrappaSession host session ───────────────── */
            Class sessionClass = objc_getClass("ATGrappaSession");
            cw_trace(trace, @"class ATGrappaSession -> %@", sessionClass != Nil ? @"FOUND" : @"NOT FOUND");
            if (sessionClass == Nil) {
                result = 3;
                goto done;
            }
            SEL initSel = sel_registerName("initWithType:");
            SEL establishSel = sel_registerName("establishHostSessionWithDeviceInfo:clientRequestData:");
            BOOL canInit = [sessionClass instancesRespondToSelector:initSel];
            BOOL canEstablish = [sessionClass instancesRespondToSelector:establishSel];
            cw_trace(trace, @"selectors: initWithType: %@, establishHostSessionWithDeviceInfo:clientRequestData: %@",
                     canInit ? @"YES" : @"NO", canEstablish ? @"YES" : @"NO");
            if (!canInit || !canEstablish) {
                result = 4;
                goto done;
            }

            id session = nil;
            @try {
                id alloced = ((id (*)(id, SEL))objc_msgSend)((id)sessionClass, sel_registerName("alloc"));
                /* type 1 = host session */
                session = ((id (*)(id, SEL, unsigned int))objc_msgSend)(alloced, initSel, 1);
            } @catch (NSException *e) {
                cw_trace(trace, @"initWithType: raised %@: %@", e.name ?: @"?", e.reason ?: @"");
                session = nil;
            }
            cw_trace(trace, @"host session (initWithType: 1) -> %@", session != nil ? @"created" : @"nil");
            if (session == nil) {
                result = 5;
                goto done;
            }

            NSData *token = nil;
            NSError *establishError = nil;
            @try {
                establishError = ((NSError * (*)(id, SEL, id, NSData **))objc_msgSend)(
                    session, establishSel, info, &token);
            } @catch (NSException *e) {
                cw_trace(trace, @"establishHostSession raised %@: %@", e.name ?: @"?", e.reason ?: @"");
                result = 6;
                goto done;
            }
            if (establishError != nil) {
                cw_trace(trace, @"establishHostSession NSError domain=%@ code=%ld desc=%@",
                         establishError.domain ?: @"?",
                         (long)establishError.code,
                         establishError.localizedDescription ?: @"");
                result = 6;
                goto done;
            }
            if (![token isKindOfClass:[NSData class]] || token.length == 0) {
                cw_trace(trace, @"establishHostSession returned no data (class=%@)",
                         token ? NSStringFromClass([token class]) : @"nil");
                result = 6;
                goto done;
            }
            if (token.length > max_len) {
                cw_trace(trace, @"token too large (%lu bytes)", (unsigned long)token.length);
                result = 7;
                goto done;
            }
            memcpy(out_buf, token.bytes, token.length);
            *out_len = token.length;
            cw_trace(trace, @"token obtained via ATGrappaSession host session (%lu bytes)",
                     (unsigned long)token.length);
            result = 0;
        } @catch (NSException *e) {
            cw_trace(trace, @"NSException %@: %@", e.name ?: @"?", e.reason ?: @"");
            if (result == 0) {
                result = 8;
            }
        }

    done:
        /* Inside the pool on purpose: `trace` may be autoreleased, so
         * copy it out before the pool drains. */
        cw_finish(diag_buf, diag_len, trace);
    }
    return result;
}
