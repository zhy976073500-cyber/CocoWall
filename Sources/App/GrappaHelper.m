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
 *   6. Only if every runtime route above has failed: a bundled-token
 *      last resort (see cw_bundled_fallback below).
 *
 * Round 2's full probe run on the device (build #25) proved every
 * runtime route dead on iOS: no framework exports ALGetGrappaToken,
 * ATGrappaDeviceInfo returns nil, the only device-info candidate is
 * the (1, 0, 1) default, and the host session's establish returns
 * ATError 0 — the path depends on CoreFP, which ships on macOS only.
 * Sage therefore approved (2026-10-28) the self-generated route: our
 * own CI macOS hosts mint a token with the identical host-session
 * flow (tools/grappa-gen) and the build embeds it in the app bundle
 * as GrappaToken.txt.
 *
 * Round 3's outcome closed the macOS route too: run #30's build log
 * proved the CI runner's AirTrafficHost is an empty shell (zero
 * Grappa classes in its image, no ALGetGrappaToken exported by the
 * framework or visible via RTLD_DEFAULT), a rented real Mac on
 * macOS 12.6 gave the same result, and round 4's on-device self-sign
 * probe (build #31) also produced nothing that passed verification.
 * With every generation route proven dead, Sage approved
 * (2026-10-30) the final fallback: the build embeds the candidate
 * token table from AirCard-iOS (MIT, by Johnny Franks / Mak5er —
 * see NOTICE at the repo root) as GrappaToken.txt, one candidate
 * per line, and cw_bundled_fallback tries each candidate against
 * the device-session self-check exactly like the reference
 * implementation does. The CI generator still runs first at build
 * time; the table is used only when it produces nothing.
 *
 * Round 4's self-sign probe stays in the failure path before the
 * bundled fallback: it dumps the signature methods' type encodings,
 * feeds them a matrix of candidate inputs (see cw_selfsign_probe
 * below), and — only if an output starts with 0x0101 AND passes the
 * device-session self-check — adopts it, traced with source
 * "selfsign". (An earlier build also demanded an exact 100-byte
 * length here, from a wrong assumption about the token size; the
 * verified tokens are 84 bytes, so the adoption rule is now
 * prefix + self-check only, with no fixed length anywhere.)
 * Outputs that fail the self-check are logged, never used.
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

/* Decode a hex string (the bundled token file's format) into data.
 * Returns nil on any malformed input. Own implementation. */
static NSData *cw_data_from_hex(NSString *hex) {
    if (hex == nil) {
        return nil;
    }
    NSUInteger len = hex.length;
    if (len == 0 || (len % 2) != 0) {
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:len / 2];
    uint8_t *bytes = (uint8_t *)data.mutableBytes;
    for (NSUInteger i = 0; i < len; i++) {
        unichar ch = [hex characterAtIndex:i];
        int nibble;
        if (ch >= '0' && ch <= '9') {
            nibble = (int)(ch - '0');
        } else if (ch >= 'a' && ch <= 'f') {
            nibble = (int)(ch - 'a') + 10;
        } else if (ch >= 'A' && ch <= 'F') {
            nibble = (int)(ch - 'A') + 10;
        } else {
            return nil;
        }
        if ((i % 2) == 0) {
            bytes[i / 2] = (uint8_t)(nibble << 4);
        } else {
            bytes[i / 2] |= (uint8_t)nibble;
        }
    }
    return data;
}

/* Device-session self-check for one bundled candidate: no NSError
 * and a non-empty response from establishDeviceSessionWithRequestData:
 * responseData: on an initWithType: 0 session means the daemon-side
 * machinery accepts the token. The outcome detail is returned through
 * detailOut for the trace; the token bytes themselves are never
 * traced. Length-agnostic: whatever was hex-decoded is checked as-is. */
static BOOL cw_verify_bundled_candidate(NSData *candidate, NSString **detailOut) {
    NSString *detail = nil;
    BOOL verified = NO;
    Class sessionClass = objc_getClass("ATGrappaSession");
    SEL devEstablishSel = sel_registerName("establishDeviceSessionWithRequestData:responseData:");
    if (sessionClass == Nil) {
        detail = @"ATGrappaSession class not found";
    } else if (![sessionClass instancesRespondToSelector:devEstablishSel]) {
        detail = @"establishDeviceSessionWithRequestData:responseData: selector missing";
    } else {
        @try {
            SEL initSel = sel_registerName("initWithType:");
            id alloced = ((id (*)(id, SEL))objc_msgSend)((id)sessionClass, sel_registerName("alloc"));
            /* type 0 = device session */
            id devSession = ((id (*)(id, SEL, unsigned int))objc_msgSend)(alloced, initSel, 0);
            if (devSession == nil) {
                detail = @"device session (initWithType: 0) -> nil";
            } else {
                NSData *response = nil;
                NSError *devError = ((NSError * (*)(id, SEL, id, NSData **))objc_msgSend)(
                    devSession, devEstablishSel, candidate, &response);
                if (devError != nil) {
                    detail = [NSString stringWithFormat:
                              @"NSError domain=%@ code=%ld desc=%@",
                              devError.domain ?: @"?",
                              (long)devError.code,
                              devError.localizedDescription ?: @""];
                } else if (![response isKindOfClass:[NSData class]] || response.length == 0) {
                    detail = @"no response data";
                } else {
                    verified = YES;
                    detail = [NSString stringWithFormat:@"response %lu bytes",
                              (unsigned long)response.length];
                }
            }
        } @catch (NSException *e) {
            detail = [NSString stringWithFormat:@"raised %@: %@",
                      e.name ?: @"?", e.reason ?: @""];
        }
    }
    if (detailOut != NULL) {
        *detailOut = detail;
    }
    return verified;
}

/* Last-resort bundled tokens.
 *
 * Reached only when every runtime route in ALGetGrappaToken failed
 * (incoming_result != 0). GrappaToken.txt in the app bundle holds one
 * hex candidate per line. Two possible sources, both produced by the
 * build (see project.yml, "Generate bundled Grappa token"): a single
 * line minted by our own tools/grappa-gen on the build host, or —
 * when the generator produces nothing — the candidate table decoded
 * from Sources/App/grappa-tokens.txt.b64.
 *
 * Token data source for the bundled table: AirCard-iOS by Johnny
 * Franks (Mak5er), https://github.com/Mak5er/AirCard-iOS, MIT License
 * — see NOTICE at the repo root.
 *
 * Mirroring the reference implementation, each candidate is tried in
 * order against the device-session self-check and the first one that
 * passes is adopted. If none passes, the first candidate is adopted
 * anyway (the reference does the same, and the daemon is the real
 * verifier). Candidate lengths are never assumed: however many bytes
 * a line hex-decodes to is what gets checked and, if adopted, copied
 * (subject only to the caller's buffer size). The trace records
 * candidate indices and step outcomes only, never token contents.
 * Returns 0 when a candidate was adopted, otherwise the incoming
 * result code unchanged. */
static int cw_bundled_fallback(NSMutableString *trace,
                               uint8_t *out_buf, size_t max_len, size_t *out_len,
                               int incoming_result) {
    cw_trace(trace, @"bundled-token fallback: runtime paths failed (rc=%d), trying GrappaToken.txt from the app bundle",
             incoming_result);
    NSString *path = [[NSBundle mainBundle] pathForResource:@"GrappaToken" ofType:@"txt"];
    if (path == nil) {
        cw_trace(trace, @"bundled-token fallback: GrappaToken.txt NOT FOUND in app bundle — no bundled token available");
        return incoming_result;
    }
    NSError *readError = nil;
    NSString *raw = [NSString stringWithContentsOfFile:path
                                              encoding:NSUTF8StringEncoding
                                                 error:&readError];
    if (raw == nil) {
        cw_trace(trace, @"bundled-token fallback: GrappaToken.txt unreadable (%@)",
                 readError.localizedDescription ?: @"unknown error");
        return incoming_result;
    }

    /* One candidate per non-empty line; malformed lines are noted by
     * index and skipped, never fatal. */
    NSMutableArray<NSData *> *candidates = [NSMutableArray array];
    NSArray<NSString *> *lines = [raw componentsSeparatedByCharactersInSet:
                                  [NSCharacterSet newlineCharacterSet]];
    NSUInteger lineIndex = 0;
    for (NSString *line in lines) {
        lineIndex++;
        NSString *hex = [line stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (hex.length == 0) {
            continue;
        }
        NSData *candidate = cw_data_from_hex(hex);
        if (candidate == nil || candidate.length == 0) {
            cw_trace(trace, @"bundled-token fallback: line %lu is not valid hex — skipped",
                     (unsigned long)lineIndex);
            continue;
        }
        [candidates addObject:candidate];
    }
    if (candidates.count == 0) {
        cw_trace(trace, @"bundled-token fallback: GrappaToken.txt present but holds no valid hex candidate");
        return incoming_result;
    }
    cw_trace(trace, @"bundled-token fallback: %lu candidate(s) decoded from GrappaToken.txt",
             (unsigned long)candidates.count);

    for (NSUInteger i = 0; i < candidates.count; i++) {
        NSData *candidate = candidates[i];
        cw_trace(trace, @"bundled-token fallback: candidate %lu/%lu (%lu bytes) — running device-session verification",
                 (unsigned long)(i + 1), (unsigned long)candidates.count,
                 (unsigned long)candidate.length);
        NSString *verifyDetail = nil;
        BOOL verified = cw_verify_bundled_candidate(candidate, &verifyDetail);
        cw_trace(trace, @"bundled-token fallback: candidate %lu verification %@ (%@)",
                 (unsigned long)(i + 1),
                 verified ? @"PASSED" : @"FAILED", verifyDetail ?: @"?");
        if (!verified) {
            continue;
        }
        if (candidate.length > max_len) {
            cw_trace(trace, @"bundled-token fallback: candidate %lu verified but too large (%lu bytes > %lu)",
                     (unsigned long)(i + 1),
                     (unsigned long)candidate.length, (unsigned long)max_len);
            return 7;
        }
        memcpy(out_buf, candidate.bytes, candidate.length);
        *out_len = candidate.length;
        cw_trace(trace, @"bundled-token fallback: candidate %lu ADOPTED (%lu bytes, verification passed)",
                 (unsigned long)(i + 1), (unsigned long)candidate.length);
        return 0;
    }

    /* No candidate passed the self-check: adopt the first one anyway,
     * mirroring the reference behaviour. */
    NSData *first = candidates[0];
    if (first.length > max_len) {
        cw_trace(trace, @"bundled-token fallback: first candidate too large (%lu bytes > %lu)",
                 (unsigned long)first.length, (unsigned long)max_len);
        return 7;
    }
    memcpy(out_buf, first.bytes, first.length);
    *out_len = first.length;
    cw_trace(trace, @"bundled-token fallback: no candidate passed verification — candidate 1 ADOPTED anyway (%lu bytes), mirroring the reference behaviour",
             (unsigned long)first.length);
    return 0;
}

/* ── Round 4: signature-method self-sign probe ─────────────────────
 *
 * The host-session route is dead on iOS (establish returns ATError 0;
 * it depends on CoreFP, which ships on macOS only) and the macOS
 * self-generation route is dead too (the CI runner's AirTrafficHost
 * is an empty shell). But ATGrappaSession itself is a real class on
 * iOS with signature methods that have never been tried:
 * createSignature:forData: and _hostCreateSignature:forData: may be
 * pure local computation that needs no service at all. This probe
 * feeds them a matrix of candidate inputs, records every outcome,
 * and adopts an output ONLY when it starts with 0x0101 and passes
 * the same device-session self-check the reference implementation
 * applies to its candidates
 * (initWithType: 0 + establishDeviceSessionWithRequestData:
 * responseData: — no NSError and a non-empty response means valid).
 * Anything that fails the self-check is logged, never used. */

/* First bytes of a data blob as hex, for prefix checks in the trace. */
static NSString *cw_hex_prefix(NSData *data, NSUInteger maxBytes) {
    if (data == nil) {
        return @"<nil>";
    }
    NSUInteger n = data.length < maxBytes ? data.length : maxBytes;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:n * 2];
    for (NSUInteger i = 0; i < n; i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    return hex;
}

/* First significant character of a runtime type string, skipping
 * qualifiers (const / bycopy / byref / oneway …). */
static char cw_type_kind(const char *type) {
    if (type == NULL) {
        return '\0';
    }
    const char *p = type;
    while (*p == 'r' || *p == 'n' || *p == 'N' || *p == 'o' ||
           *p == 'O' || *p == 'R' || *p == 'V') {
        p++;
    }
    return *p;
}

/* Type encodings of every ATGrappaSession method this project cares
 * about, instance and class side, recorded verbatim so the next
 * route decision reads parameter/return shapes from evidence. */
static void cw_dump_type_encodings(NSMutableString *trace, Class sessionClass) {
    static const char *const names[] = {
        "createSignature:forData:",
        "_hostCreateSignature:forData:",
        "_deviceCreateSignature:forData:",
        "verifySignature:forData:",
        "beginHostSessionWithDeviceResponseData:",
        "establishDeviceSessionWithRequestData:responseData:",
        "establishHostSessionWithDeviceInfo:clientRequestData:",
        "deviceInfo",
        "initWithType:",
    };
    for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        SEL sel = sel_registerName(names[i]);
        Method im = class_getInstanceMethod(sessionClass, sel);
        Method cm = class_getClassMethod(sessionClass, sel);
        cw_trace(trace, @"type encoding %s: instance=%s class=%s",
                 names[i],
                 im != NULL ? (method_getTypeEncoding(im) ?: "<null>") : "<absent>",
                 cm != NULL ? (method_getTypeEncoding(cm) ?: "<null>") : "<absent>");
    }
}

/* Device-session self-check for a locally minted candidate: no
 * NSError and a non-empty response means the daemon-side machinery
 * accepts the token. */
static BOOL cw_device_session_verify(NSMutableString *trace, Class sessionClass,
                                     NSData *token, NSString *sourceLabel) {
    SEL devEstablishSel = sel_registerName("establishDeviceSessionWithRequestData:responseData:");
    if (![sessionClass instancesRespondToSelector:devEstablishSel]) {
        cw_trace(trace, @"selfsign verify (%@): establishDeviceSession selector missing", sourceLabel);
        return NO;
    }
    @try {
        id alloced = ((id (*)(id, SEL))objc_msgSend)((id)sessionClass, sel_registerName("alloc"));
        /* type 0 = device session */
        id devSession = ((id (*)(id, SEL, unsigned int))objc_msgSend)(
            alloced, sel_registerName("initWithType:"), 0);
        if (devSession == nil) {
            cw_trace(trace, @"selfsign verify (%@): device session (initWithType: 0) -> nil", sourceLabel);
            return NO;
        }
        NSData *response = nil;
        NSError *devError = ((NSError * (*)(id, SEL, id, NSData **))objc_msgSend)(
            devSession, devEstablishSel, token, &response);
        if (devError != nil) {
            cw_trace(trace, @"selfsign verify (%@): FAILED — NSError domain=%@ code=%ld desc=%@",
                     sourceLabel, devError.domain ?: @"?", (long)devError.code,
                     devError.localizedDescription ?: @"");
            return NO;
        }
        if (![response isKindOfClass:[NSData class]] || response.length == 0) {
            cw_trace(trace, @"selfsign verify (%@): FAILED — no response data", sourceLabel);
            return NO;
        }
        cw_trace(trace, @"selfsign verify (%@): PASSED (response %lu bytes)",
                 sourceLabel, (unsigned long)response.length);
        return YES;
    } @catch (NSException *e) {
        cw_trace(trace, @"selfsign verify (%@): raised %@: %@",
                 sourceLabel, e.name ?: @"?", e.reason ?: @"");
        return NO;
    }
}

/* Record one candidate output. Only a token-shaped output (0x0101
 * prefix — no fixed length; verified tokens are 84 bytes, and an
 * earlier 100-byte assumption here was wrong) that passes the
 * device-session self-check is adopted into out_buf (returns YES);
 * everything else is trace-only. */
static BOOL cw_consider_output(NSMutableString *trace, Class sessionClass,
                               id output, NSString *label,
                               uint8_t *out_buf, size_t max_len, size_t *out_len) {
    if (output == nil) {
        cw_trace(trace, @"selfsign %@: -> nil", label);
        return NO;
    }
    if (![output isKindOfClass:[NSData class]]) {
        cw_trace(trace, @"selfsign %@: -> non-data (class=%@)", label,
                 NSStringFromClass([output class]));
        return NO;
    }
    NSData *data = (NSData *)output;
    cw_trace(trace, @"selfsign %@: -> data len=%lu prefix=%@",
             label, (unsigned long)data.length, cw_hex_prefix(data, 4));
    if (data.length < 2) {
        return NO;
    }
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    if (bytes[0] != 0x01 || bytes[1] != 0x01) {
        cw_trace(trace, @"selfsign %@: prefix is not 0101 — not token-shaped", label);
        return NO;
    }
    cw_trace(trace, @"selfsign %@: token-shaped (%lu bytes, 0101 prefix) — running device-session self-check",
             label, (unsigned long)data.length);
    if (!cw_device_session_verify(trace, sessionClass, data, label)) {
        cw_trace(trace, @"selfsign %@: self-check FAILED — output logged only, NOT used as token", label);
        return NO;
    }
    if (data.length > max_len) {
        cw_trace(trace, @"selfsign %@: verified but too large for the output buffer (%lu > %lu)",
                 label, (unsigned long)data.length, (unsigned long)max_len);
        return NO;
    }
    memcpy(out_buf, data.bytes, data.length);
    *out_len = data.length;
    cw_trace(trace, @"selfsign %@: token ADOPTED (source=selfsign, %lu bytes)",
             label, (unsigned long)data.length);
    return YES;
}

/* One createSignature-style call. The call is only made when the
 * method's own type encoding says both explicit arguments are
 * objects and the return value is an object; any other shape is
 * recorded from the encoding instead of being invoked blind. */
static BOOL cw_try_signature_call(NSMutableString *trace, Class sessionClass,
                                  id receiver, BOOL classReceiver, SEL sel,
                                  NSString *label,
                                  NSData *first, NSData *second,
                                  uint8_t *out_buf, size_t max_len, size_t *out_len) {
    Method m = classReceiver ? class_getClassMethod(sessionClass, sel)
                             : class_getInstanceMethod(sessionClass, sel);
    if (m == NULL) {
        cw_trace(trace, @"selfsign %@: method absent on this side", label);
        return NO;
    }
    char retType[64] = {0};
    char arg2[64] = {0};
    char arg3[64] = {0};
    method_getReturnType(m, retType, sizeof(retType));
    method_getArgumentType(m, 2, arg2, sizeof(arg2));
    method_getArgumentType(m, 3, arg3, sizeof(arg3));
    if (cw_type_kind(arg2) != '@' || cw_type_kind(arg3) != '@') {
        cw_trace(trace, @"selfsign %@: skipped — argument types %s / %s are not both objects",
                 label, arg2, arg3);
        return NO;
    }
    if (cw_type_kind(retType) != '@') {
        cw_trace(trace, @"selfsign %@: skipped — return type %s is not an object", label, retType);
        return NO;
    }
    id output = nil;
    @try {
        output = ((id (*)(id, SEL, id, id))objc_msgSend)(receiver, sel, first, second);
    } @catch (NSException *e) {
        cw_trace(trace, @"selfsign %@: raised %@: %@", label, e.name ?: @"?", e.reason ?: @"");
        return NO;
    }
    return cw_consider_output(trace, sessionClass, output, label, out_buf, max_len, out_len);
}

static int cw_selfsign_probe(NSMutableString *trace,
                             uint32_t version, uint32_t device_type, uint32_t protocol_version,
                             uint8_t *out_buf, size_t max_len, size_t *out_len,
                             int incoming_result) {
    cw_trace(trace, @"selfsign probe: minting locally via ATGrappaSession signature methods");
    Class sessionClass = objc_getClass("ATGrappaSession");
    if (sessionClass == Nil) {
        cw_trace(trace, @"selfsign probe: ATGrappaSession class NOT FOUND — probe skipped");
        return incoming_result;
    }
    cw_dump_type_encodings(trace, sessionClass);

    /* Candidate inputs. (a)/(b) are the fixed (1, 0, 1) triple — the
     * only triple a token is known to be minted for — as binary and
     * XML plist; (d) is the daemon's GrappaSupportInfo triple exactly
     * as passed into this function, binary plist; (c) is empty. */
    NSDictionary *fixedTriple = @{ @"version" : @1, @"deviceType" : @0, @"protocolVersion" : @1 };
    NSDictionary *daemonTriple = @{
        @"version" : @(version),
        @"deviceType" : @(device_type),
        @"protocolVersion" : @(protocol_version),
    };
    NSError *serError = nil;
    NSData *binFixed = [NSPropertyListSerialization dataWithPropertyList:fixedTriple
                                                                  format:NSPropertyListBinaryFormat_v1_0
                                                                 options:0
                                                                   error:&serError];
    if (binFixed == nil) {
        cw_trace(trace, @"selfsign probe: binary plist of fixed triple failed (%@)",
                 serError.localizedDescription ?: @"?");
    }
    serError = nil;
    NSData *xmlFixed = [NSPropertyListSerialization dataWithPropertyList:fixedTriple
                                                                  format:NSPropertyListXMLFormat_v1_0
                                                                 options:0
                                                                   error:&serError];
    if (xmlFixed == nil) {
        cw_trace(trace, @"selfsign probe: XML plist of fixed triple failed (%@)",
                 serError.localizedDescription ?: @"?");
    }
    serError = nil;
    NSData *binDaemon = [NSPropertyListSerialization dataWithPropertyList:daemonTriple
                                                                   format:NSPropertyListBinaryFormat_v1_0
                                                                  options:0
                                                                    error:&serError];
    if (binDaemon == nil) {
        cw_trace(trace, @"selfsign probe: binary plist of daemon triple failed (%@)",
                 serError.localizedDescription ?: @"?");
    }
    NSData *empty = [NSData data];
    NSArray<NSDictionary *> *inputs = @[
        @{ @"label" : @"(a) fixed-triple binary plist", @"data" : binFixed ?: empty },
        @{ @"label" : @"(b) fixed-triple XML plist", @"data" : xmlFixed ?: empty },
        @{ @"label" : @"(c) empty data", @"data" : empty },
        @{ @"label" : @"(d) daemon GrappaSupportInfo binary plist", @"data" : binDaemon ?: empty },
    ];
    for (NSDictionary *input in inputs) {
        cw_trace(trace, @"selfsign probe: candidate %@ is %lu bytes",
                 input[@"label"], (unsigned long)((NSData *)input[@"data"]).length);
    }

    /* Host-type instance for the instance-side attempts. */
    id hostSession = nil;
    @try {
        id alloced = ((id (*)(id, SEL))objc_msgSend)((id)sessionClass, sel_registerName("alloc"));
        hostSession = ((id (*)(id, SEL, unsigned int))objc_msgSend)(
            alloced, sel_registerName("initWithType:"), 1);
    } @catch (NSException *e) {
        cw_trace(trace, @"selfsign probe: host session init raised %@: %@",
                 e.name ?: @"?", e.reason ?: @"");
        hostSession = nil;
    }
    cw_trace(trace, @"selfsign probe: host session (initWithType: 1) -> %@",
             hostSession != nil ? @"created" : @"nil");

    /* Signature attempts: both selectors × instance/class receivers
     * × every candidate input × both argument orders (the semantics
     * of the two parameter slots are unknown, so the candidate data
     * is tried in each). The empty candidate has a single order. */
    static const char *const sigNames[] = {
        "createSignature:forData:",
        "_hostCreateSignature:forData:",
    };
    for (unsigned s = 0; s < sizeof(sigNames) / sizeof(sigNames[0]); s++) {
        SEL sel = sel_registerName(sigNames[s]);
        for (int r = 0; r < 2; r++) {
            BOOL classReceiver = (r == 1);
            NSString *receiverLabel = classReceiver ? @"class" : @"host-instance";
            if (classReceiver) {
                if (class_getClassMethod(sessionClass, sel) == NULL) {
                    cw_trace(trace, @"selfsign %s via class: no class method — skipped", sigNames[s]);
                    continue;
                }
            } else {
                if (hostSession == nil) {
                    cw_trace(trace, @"selfsign %s via host-instance: no host session — skipped", sigNames[s]);
                    continue;
                }
                if (class_getInstanceMethod(sessionClass, sel) == NULL) {
                    cw_trace(trace, @"selfsign %s via host-instance: no instance method — skipped", sigNames[s]);
                    continue;
                }
            }
            id receiver = classReceiver ? (id)sessionClass : hostSession;
            for (NSDictionary *input in inputs) {
                NSData *data = (NSData *)input[@"data"];
                int orders = data.length == 0 ? 1 : 2;
                for (int o = 0; o < orders; o++) {
                    NSData *first = o == 0 ? data : empty;
                    NSData *second = o == 0 ? empty : data;
                    NSString *label = [NSString stringWithFormat:@"%s via %@, %@: %@",
                                       sigNames[s], receiverLabel, input[@"label"],
                                       o == 0 ? @"input->arg1, empty->arg2"
                                              : @"empty->arg1, input->arg2"];
                    if (cw_try_signature_call(trace, sessionClass, receiver, classReceiver,
                                              sel, label, first, second,
                                              out_buf, max_len, out_len)) {
                        return 0;
                    }
                }
            }
        }
    }

    /* beginHostSessionWithDeviceResponseData: — fed the daemon's
     * GrappaSupportInfo serialization as the "device response". */
    SEL beginSel = sel_registerName("beginHostSessionWithDeviceResponseData:");
    Method beginMethod = class_getInstanceMethod(sessionClass, beginSel);
    if (beginMethod == NULL) {
        cw_trace(trace, @"selfsign beginHostSessionWithDeviceResponseData:: method absent — skipped");
    } else if (hostSession == nil) {
        cw_trace(trace, @"selfsign beginHostSessionWithDeviceResponseData:: no host session — skipped");
    } else {
        char retType[64] = {0};
        char arg2[64] = {0};
        method_getReturnType(beginMethod, retType, sizeof(retType));
        method_getArgumentType(beginMethod, 2, arg2, sizeof(arg2));
        NSString *beginLabel = @"beginHostSessionWithDeviceResponseData: (daemon GrappaSupportInfo binary plist)";
        if (cw_type_kind(arg2) != '@') {
            cw_trace(trace, @"selfsign %@: skipped — argument type %s is not an object",
                     beginLabel, arg2);
        } else if (cw_type_kind(retType) == '@') {
            id output = nil;
            BOOL raised = NO;
            @try {
                output = ((id (*)(id, SEL, id))objc_msgSend)(hostSession, beginSel, binDaemon ?: empty);
            } @catch (NSException *e) {
                raised = YES;
                cw_trace(trace, @"selfsign %@: raised %@: %@", beginLabel, e.name ?: @"?", e.reason ?: @"");
            }
            if (!raised && cw_consider_output(trace, sessionClass, output, beginLabel,
                                              out_buf, max_len, out_len)) {
                return 0;
            }
        } else if (cw_type_kind(retType) == 'B' || cw_type_kind(retType) == 'c') {
            BOOL ok = NO;
            @try {
                ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(hostSession, beginSel, binDaemon ?: empty);
            } @catch (NSException *e) {
                cw_trace(trace, @"selfsign %@: raised %@: %@", beginLabel, e.name ?: @"?", e.reason ?: @"");
            }
            cw_trace(trace, @"selfsign %@: -> BOOL %@ (no data returned — nothing to adopt)",
                     beginLabel, ok ? @"YES" : @"NO");
        } else {
            cw_trace(trace, @"selfsign %@: skipped — return type %s is neither object nor BOOL",
                     beginLabel, retType);
        }
    }

    cw_trace(trace, @"selfsign probe: exhausted — no locally minted output passed verification");
    return incoming_result;
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
        /* Failure-path hooks: every failure lands here (fall-through
         * and gotos alike). Round 4's self-sign probe gets its turn
         * first — it is the only remaining runtime lead on iOS — and
         * the bundled-token last resort runs after it. */
        if (result != 0) {
            result = cw_selfsign_probe(trace, version, device_type, protocol_version,
                                       out_buf, max_len, out_len, result);
        }
        if (result != 0) {
            result = cw_bundled_fallback(trace, out_buf, max_len, out_len, result);
        }
        /* Inside the pool on purpose: `trace` may be autoreleased, so
         * copy it out before the pool drains. */
        cw_finish(diag_buf, diag_len, trace);
    }
    return result;
}
