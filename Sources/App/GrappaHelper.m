/* See GrappaHelper.h. Own implementation.
 *
 * Round 2 probe design. Round 1's on-device trace proved the first
 * build short-circuited: it stopped loading frameworks at the first
 * dlopen success (AirTrafficDevice) and only ever probed that one
 * handle, while the recorded protocol facts place the framework entry
 * ALGetGrappaToken in AirTrafficHost — a framework whose very
 * existence on iOS had never been tested. This build therefore:
 *
 *   1. dlopens BOTH AirTrafficDevice and AirTrafficHost and records
 *      each result (with raw dlerror) — no short-circuit.
 *   2. In EVERY loaded framework, dlsym-probes both ALGetGrappaToken
 *      and ATGrappaDeviceInfo and records hit/miss per framework.
 *   3. Dumps runtime introspection: the image that defines
 *      ATGrappaSession, every Grappa-named class in each loaded
 *      framework image, and ATGrappaSession's full instance- and
 *      class-method lists — so a failing run still hands back the map
 *      needed to pick the next route without guessing selectors.
 *   4. Calls ATGrappaDeviceInfo in every framework that exports it
 *      and records the returned object's class and, for dictionaries,
 *      all keys plus the version/deviceType/protocolVersion values.
 *   5. Tries, in order: each framework's own ALGetGrappaToken entry;
 *      then an ATGrappaSession host session (initWithType: 1,
 *      establishHostSessionWithDeviceInfo:clientRequestData:) once
 *      per candidate device-info dictionary — daemon-supplied triple,
 *      each framework-returned dictionary, then the (1, 0, 1)
 *      defaults — recording every NSError verbatim.
 *
 * The token, when one is produced, is generated on this device at
 * runtime. There is deliberately no fallback to pre-generated token
 * values: the reference implementation's iOS fallback table (authentic
 * tokens minted by CoreFP on macOS) is recorded as a protocol fact in
 * research/, but its values are not ours to ship.
 */

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdarg.h>
#import <stdlib.h>
#import <string.h>

/* Signature shared by this helper and the framework-exported entry of
 * the same name. */
typedef int (*CWGrappaTokenFn)(uint32_t, uint32_t, uint32_t,
                               uint8_t *, size_t, size_t *,
                               char *, size_t);
/* The frameworks export a no-argument function returning the device
 * info dictionary used for Grappa sessions. */
typedef id (*CWGrappaDeviceInfoFn)(void);

typedef struct {
    const char *name;
    const char *path;
    void *handle;
    CWGrappaTokenFn tokenFn;
    CWGrappaDeviceInfoFn infoFn;
} CWFramework;

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

/* All method names of a class (instance methods, or class methods
 * when meta is YES), sorted, comma-joined. */
static NSString *cw_method_names(Class cls, BOOL meta) {
    Class target = meta ? object_getClass((id)cls) : cls;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(target, &count);
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        const char *name = sel_getName(sel);
        [names addObject:name ? @(name) : @"?"];
    }
    free(methods);
    [names sortUsingSelector:@selector(compare:)];
    return [names componentsJoinedByString:@","];
}

/* Describe an ATGrappaDeviceInfo result into the trace: its class,
 * and for dictionaries every key plus the Grappa triple values. */
static void cw_describe_info(NSMutableString *trace, const char *fwName, id produced) {
    if (produced == nil) {
        cw_trace(trace, @"%s ATGrappaDeviceInfo -> returned nil", fwName);
        return;
    }
    if (![produced isKindOfClass:[NSDictionary class]]) {
        cw_trace(trace, @"%s ATGrappaDeviceInfo -> returned non-dictionary class=%@",
                 fwName, NSStringFromClass([produced class]));
        return;
    }
    NSDictionary *dict = (NSDictionary *)produced;
    NSArray<NSString *> *keys = [dict.allKeys sortedArrayUsingSelector:@selector(compare:)];
    cw_trace(trace, @"%s ATGrappaDeviceInfo -> dictionary keys=[%@] version=%@ deviceType=%@ protocolVersion=%@",
             fwName,
             [keys componentsJoinedByString:@","],
             dict[@"version"] ?: @"<absent>",
             dict[@"deviceType"] ?: @"<absent>",
             dict[@"protocolVersion"] ?: @"<absent>");
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
            /* ── Step 1: load BOTH frameworks, no short-circuit ───── */
            CWFramework frameworks[2] = {
                { "AirTrafficDevice",
                  "/System/Library/PrivateFrameworks/AirTrafficDevice.framework/AirTrafficDevice",
                  NULL, NULL, NULL },
                { "AirTrafficHost",
                  "/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost",
                  NULL, NULL, NULL },
            };
            unsigned loadedCount = 0;
            for (unsigned i = 0; i < 2; i++) {
                dlerror(); /* clear */
                frameworks[i].handle = dlopen(frameworks[i].path, RTLD_NOW);
                if (frameworks[i].handle != NULL) {
                    loadedCount++;
                    cw_trace(trace, @"dlopen %s -> OK", frameworks[i].name);
                } else {
                    const char *err = dlerror();
                    cw_trace(trace, @"dlopen %s -> FAIL (%s)", frameworks[i].name, err ?: "unknown");
                }
            }
            if (loadedCount == 0) {
                cw_trace(trace, @"both AirTraffic frameworks failed to load");
                result = 2;
                goto done;
            }

            /* ── Step 2: probe both symbols in EVERY loaded framework */
            for (unsigned i = 0; i < 2; i++) {
                if (frameworks[i].handle == NULL) {
                    continue;
                }
                dlerror(); /* clear */
                frameworks[i].tokenFn =
                    (CWGrappaTokenFn)dlsym(frameworks[i].handle, "ALGetGrappaToken");
                if (frameworks[i].tokenFn != NULL) {
                    cw_trace(trace, @"%s symbol ALGetGrappaToken -> FOUND", frameworks[i].name);
                } else {
                    const char *err = dlerror();
                    cw_trace(trace, @"%s symbol ALGetGrappaToken -> NOT FOUND (%s)",
                             frameworks[i].name, err ?: "no dlerror");
                }
                dlerror(); /* clear */
                frameworks[i].infoFn =
                    (CWGrappaDeviceInfoFn)dlsym(frameworks[i].handle, "ATGrappaDeviceInfo");
                if (frameworks[i].infoFn != NULL) {
                    cw_trace(trace, @"%s symbol ATGrappaDeviceInfo -> FOUND", frameworks[i].name);
                } else {
                    const char *err = dlerror();
                    cw_trace(trace, @"%s symbol ATGrappaDeviceInfo -> NOT FOUND (%s)",
                             frameworks[i].name, err ?: "no dlerror");
                }
            }

            /* ── Step 3: introspection dump ───────────────────────── */
            Class sessionClass = objc_getClass("ATGrappaSession");
            cw_trace(trace, @"class ATGrappaSession -> %@", sessionClass != Nil ? @"FOUND" : @"NOT FOUND");
            if (sessionClass != Nil) {
                const char *image = class_getImageName(sessionClass);
                cw_trace(trace, @"ATGrappaSession defined in image: %s", image ?: "<unknown>");
                cw_trace(trace, @"ATGrappaSession instance methods: %@",
                         cw_method_names(sessionClass, NO));
                cw_trace(trace, @"ATGrappaSession class methods: %@",
                         cw_method_names(sessionClass, YES));
            }
            for (unsigned i = 0; i < 2; i++) {
                if (frameworks[i].handle == NULL) {
                    continue;
                }
                unsigned int classCount = 0;
                const char **classNames = objc_copyClassNamesForImage(frameworks[i].path, &classCount);
                NSMutableArray<NSString *> *grappaClasses = [NSMutableArray array];
                for (unsigned int c = 0; c < classCount; c++) {
                    NSString *name = classNames[c] ? @(classNames[c]) : @"";
                    if ([name rangeOfString:@"Grappa" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                        [grappaClasses addObject:name];
                    }
                }
                free(classNames);
                cw_trace(trace, @"%s image Grappa classes (%lu of %u): %@",
                         frameworks[i].name,
                         (unsigned long)grappaClasses.count, classCount,
                         [grappaClasses componentsJoinedByString:@","]);
            }

            /* ── Step 4: gather candidate device-info dictionaries ── */
            NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
            NSMutableArray<NSString *> *candidateSources = [NSMutableArray array];
            NSMutableSet<NSString *> *seenSignatures = [NSMutableSet set];
            void (^addCandidate)(NSDictionary *, NSString *) =
                ^(NSDictionary *dict, NSString *source) {
                    NSString *signature = [dict description] ?: @"";
                    if (![seenSignatures containsObject:signature]) {
                        [seenSignatures addObject:signature];
                        [candidates addObject:dict];
                        [candidateSources addObject:source];
                    }
                };

            if (device_type != 0) {
                addCandidate(@{
                    @"version" : @(version != 0 ? version : 1),
                    @"deviceType" : @(device_type),
                    @"protocolVersion" : @(protocol_version != 0 ? protocol_version : 1),
                }, @"daemon triple");
            }
            for (unsigned i = 0; i < 2; i++) {
                if (frameworks[i].infoFn == NULL) {
                    continue;
                }
                id produced = nil;
                @try {
                    produced = frameworks[i].infoFn();
                } @catch (NSException *e) {
                    cw_trace(trace, @"%s ATGrappaDeviceInfo raised %@: %@",
                             frameworks[i].name, e.name ?: @"?", e.reason ?: @"");
                }
                cw_describe_info(trace, frameworks[i].name, produced);
                if ([produced isKindOfClass:[NSDictionary class]]) {
                    addCandidate((NSDictionary *)produced,
                                 [NSString stringWithFormat:@"%s ATGrappaDeviceInfo", frameworks[i].name]);
                }
            }
            addCandidate(@{
                @"version" : @(version != 0 ? version : 1),
                @"deviceType" : @0,
                @"protocolVersion" : @(protocol_version != 0 ? protocol_version : 1),
            }, @"defaults (1,0,1)");
            cw_trace(trace, @"device-info candidates: %lu", (unsigned long)candidates.count);

            /* ── Step 5: each framework's own ALGetGrappaToken ────── */
            for (unsigned i = 0; i < 2 && result == 0; i++) {
                if (frameworks[i].tokenFn == NULL) {
                    continue;
                }
                uint8_t fwBuf[512];
                size_t fwLen = 0;
                char fwDiag[512] = {0};
                int fwRc = frameworks[i].tokenFn(version, device_type, protocol_version,
                                                 fwBuf, sizeof(fwBuf), &fwLen,
                                                 fwDiag, sizeof(fwDiag));
                cw_trace(trace, @"%s ALGetGrappaToken call rc=%d len=%lu diag=%s",
                         frameworks[i].name, fwRc, (unsigned long)fwLen, fwDiag);
                if (fwRc == 0 && fwLen > 0) {
                    if (fwLen > max_len) {
                        cw_trace(trace, @"token too large (%lu bytes)", (unsigned long)fwLen);
                        result = 7;
                        goto done;
                    }
                    memcpy(out_buf, fwBuf, fwLen);
                    *out_len = fwLen;
                    cw_trace(trace, @"token obtained via %s ALGetGrappaToken (%lu bytes)",
                             frameworks[i].name, (unsigned long)fwLen);
                    result = 0;
                    goto done;
                }
            }

            /* ── Step 6: ATGrappaSession host session per candidate ─ */
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

            result = 6;
            for (NSUInteger c = 0; c < candidates.count && result != 0; c++) {
                NSDictionary *info = candidates[c];
                cw_trace(trace, @"host session attempt with info from %@ (version=%@ deviceType=%@ protocolVersion=%@)",
                         candidateSources[c],
                         info[@"version"] ?: @"<absent>",
                         info[@"deviceType"] ?: @"<absent>",
                         info[@"protocolVersion"] ?: @"<absent>");

                id session = nil;
                @try {
                    id alloced = ((id (*)(id, SEL))objc_msgSend)((id)sessionClass, sel_registerName("alloc"));
                    /* type 1 = host session */
                    session = ((id (*)(id, SEL, unsigned int))objc_msgSend)(alloced, initSel, 1);
                } @catch (NSException *e) {
                    cw_trace(trace, @"initWithType: raised %@: %@", e.name ?: @"?", e.reason ?: @"");
                    session = nil;
                }
                if (session == nil) {
                    cw_trace(trace, @"host session (initWithType: 1) -> nil");
                    result = 5;
                    continue;
                }

                NSData *token = nil;
                NSError *establishError = nil;
                @try {
                    establishError = ((NSError * (*)(id, SEL, id, NSData **))objc_msgSend)(
                        session, establishSel, info, &token);
                } @catch (NSException *e) {
                    cw_trace(trace, @"establishHostSession raised %@: %@", e.name ?: @"?", e.reason ?: @"");
                    continue;
                }
                if (establishError != nil) {
                    cw_trace(trace, @"establishHostSession NSError domain=%@ code=%ld desc=%@",
                             establishError.domain ?: @"?",
                             (long)establishError.code,
                             establishError.localizedDescription ?: @"");
                    result = 6;
                    continue;
                }
                if (![token isKindOfClass:[NSData class]] || token.length == 0) {
                    cw_trace(trace, @"establishHostSession returned no data (class=%@)",
                             token ? NSStringFromClass([token class]) : @"nil");
                    result = 6;
                    continue;
                }
                if (token.length > max_len) {
                    cw_trace(trace, @"token too large (%lu bytes)", (unsigned long)token.length);
                    result = 7;
                    goto done;
                }
                memcpy(out_buf, token.bytes, token.length);
                *out_len = token.length;
                cw_trace(trace, @"token obtained via ATGrappaSession host session with info from %@ (%lu bytes)",
                         candidateSources[c], (unsigned long)token.length);
                result = 0;
            }
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
