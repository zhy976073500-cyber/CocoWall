/* GrappaHelper — produces an AirTraffic "Grappa" session token on the
 * device at runtime, exposed to the Rust core as the plain C function
 * ALGetGrappaToken. The Rust core links this function directly (no
 * dlsym): a same-named symbol that nothing references at link time is
 * internalised by the linker and can never be found through
 * dlsym(RTLD_DEFAULT) in the main executable — that is how the previous
 * build ended up reporting "symbol not found" on device even though
 * this file was compiled in.
 *
 * The token is generated on this device at sync time (see the .m for
 * the step-by-step approach). There is intentionally no fallback to
 * pre-generated token values: if the device cannot produce a token,
 * the function returns non-zero and says exactly which step failed.
 */
#ifndef COCOWALL_GRAPPA_HELPER_H
#define COCOWALL_GRAPPA_HELPER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Returns 0 on success and writes the token bytes to out_buf
 * (*out_len receives the byte count). On failure returns non-zero.
 * diag_buf always receives a step-by-step diagnostic trace (framework
 * loads, symbol probes, session results, raw system errors), on
 * success and on failure alike, so the caller can log the full story. */
__attribute__((visibility("default"), used))
int ALGetGrappaToken(uint32_t version,
                     uint32_t device_type,
                     uint32_t protocol_version,
                     uint8_t *out_buf,
                     size_t max_len,
                     size_t *out_len,
                     char *diag_buf,
                     size_t diag_len);

#ifdef __cplusplus
}
#endif

#endif /* COCOWALL_GRAPPA_HELPER_H */
