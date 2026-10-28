/* GrappaHelper — produces an AirTraffic "Grappa" session token via the
 * device's private AirTraffic frameworks, exposed to the Rust core as
 * the plain C function ALGetGrappaToken (resolved with dlsym, so this
 * file has no link-time coupling to the core).
 *
 * The private API surface is probed defensively: frameworks are
 * dlopen'ed, classes and selectors are checked before use, and every
 * failure path reports a concrete reason into err_buf and returns
 * non-zero. Callers treat a missing token as a degraded handshake,
 * never as a success.
 */
#ifndef COCOWALL_GRAPPA_HELPER_H
#define COCOWALL_GRAPPA_HELPER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Returns 0 on success and writes the token bytes to out_buf
 * (*out_len receives the byte count). On failure returns non-zero and
 * writes a human-readable reason into err_buf. */
int ALGetGrappaToken(uint32_t version,
                     uint32_t device_type,
                     uint32_t protocol_version,
                     uint8_t *out_buf,
                     size_t max_len,
                     size_t *out_len,
                     char *err_buf,
                     size_t err_len);

#ifdef __cplusplus
}
#endif

#endif /* COCOWALL_GRAPPA_HELPER_H */
