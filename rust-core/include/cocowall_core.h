// CocoWall core — C FFI surface (hand-maintained mirror of src/lib.rs;
// keep in sync until cbindgen generation is wired into the build).
#ifndef COCOWALL_CORE_H
#define COCOWALL_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*CWLogCallback)(void *ctx, const char *msg);
typedef void (*CWPairReadyCallback)(void *ctx,
                                     const char *service_id,
                                     uint16_t port,
                                     const char *const *txt_keys,
                                     const char *const *txt_vals,
                                     size_t txt_count);
typedef void (*CWPairPinCallback)(const char *pin, void *ctx);

/* Return codes: 0 = OK, 1 = failed (see the out error string),
   2 = invalid argument, -1 = not implemented (the injection ring has
   not landed; the error string says so in plain words). */

/* Link canary: static NUL-terminated version string, e.g.
   "cocowall-core 0.1.0 · idevice 0.1.68". Do NOT free the result. */
const char *cw_core_version(void);

void cw_string_free(char *p);
int32_t cw_log_init(CWLogCallback cb, void *ctx);

typedef struct {
    char *error;
    char *device_name;
    char *device_udid;
    char *pairing_file_path;
    char *host_alt_irk_hex;
} CWPairResult;

int32_t cw_pairing_run_host(const char *bind_addr,
                            uint16_t port,
                            const char *name,
                            const char *model,
                            const char *out_path,
                            const char *host_alt_irk_hex,
                            CWPairReadyCallback ready_cb,
                            CWPairPinCallback pin_cb,
                            void *ctx,
                            CWPairResult *out);
void cw_pairing_result_free(CWPairResult *r);

int32_t cw_exploit_run(const char *pairing_path,
                       const char *target,
                       CWLogCallback log_cb,
                       void *ctx,
                       char **out_json,
                       char **out_error);
int32_t cw_exploit_write_dir(const char *pairing_path,
                             const char *source_dir,
                             const char *target_dir,
                             CWLogCallback log_cb,
                             void *ctx,
                             char **out_error);
int32_t cw_exploit_inject_folder(const char *pairing_path,
                                 const char *folder_path,
                                 const char *target_parent_dir,
                                 const char *dest_name,
                                 CWLogCallback log_cb,
                                 void *ctx,
                                 char **out_error);
int32_t cw_find_app_container(const char *pairing_path,
                              const char *bundle_id,
                              CWLogCallback log_cb,
                              void *ctx,
                              char **out_container,
                              char **out_error);
int32_t cw_device_respring(const char *pairing_path,
                           CWLogCallback log_cb,
                           void *ctx,
                           char **out_error);
/* Full wallpaper apply for one descriptor folder (container lookup,
 * staging-copy prep with a fresh UUID + identifier rewrite, primary
 * inject, iOS 18+ dual inject, PosterBoard refresh plist). Blocking.
 * On success *out_report receives a JSON object; free with
 * cw_string_free. Respring stays a separate explicit step. */
int32_t cw_wallpaper_apply(const char *pairing_path,
                           const char *descriptor_dir,
                           CWLogCallback log_cb,
                           void *ctx,
                           char **out_report,
                           char **out_error);

int32_t cw_set_target_host(const char *host);
void cw_clear_target_hosts(void);

#ifdef __cplusplus
}
#endif

#endif /* COCOWALL_CORE_H */
