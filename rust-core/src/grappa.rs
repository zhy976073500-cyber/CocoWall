//! Grappa token generation for the AirTraffic sync handshake.
//!
//! The token itself is produced by `ALGetGrappaToken`, a small
//! Objective-C helper compiled into the app (Sources/App/GrappaHelper.m)
//! that drives the device's private AirTraffic frameworks. It is resolved
//! dynamically with dlsym so this crate carries no link-time dependency
//! on it; absence of the symbol is reported, never papered over.

use std::ffi::CStr;

type GetGrappaTokenFn = unsafe extern "C" fn(
    in_version: u32,
    in_device_type: u32,
    in_protocol_version: u32,
    out_buf: *mut u8,
    max_len: usize,
    out_len: *mut usize,
    err_buf: *mut libc::c_char,
    err_len: usize,
) -> libc::c_int;

/// Ask the in-app helper for a Grappa client token. `device_info` carries
/// the (version, deviceType, protocolVersion) triple reported by the
/// device during the sync handshake; defaults to (1, 0, 1).
pub fn generate_grappa_token(
    device_info: Option<(u32, u32, u32)>,
    log: &crate::device_log::Logger,
) -> Option<Vec<u8>> {
    unsafe {
        let sym = libc::dlsym(libc::RTLD_DEFAULT, b"ALGetGrappaToken\0".as_ptr() as _);
        if sym.is_null() {
            log.log("同步：ALGetGrappaToken 符号不存在（GrappaHelper 未编入 App）");
            return None;
        }
        let get_token: GetGrappaTokenFn = std::mem::transmute(sym);
        let (ver, dt, pv) = device_info.unwrap_or((1, 0, 1));
        let mut buf = vec![0u8; 512];
        let mut out_len: usize = 0;
        let mut err_buf = [0 as libc::c_char; 256];
        let rc = get_token(
            ver,
            dt,
            pv,
            buf.as_mut_ptr(),
            buf.len(),
            &mut out_len,
            err_buf.as_mut_ptr(),
            err_buf.len(),
        );
        if rc != 0 || out_len == 0 {
            let err = CStr::from_ptr(err_buf.as_ptr()).to_string_lossy();
            log.log(format!("同步：Grappa token 生成失败（rc={rc}）: {err}"));
            return None;
        }
        buf.truncate(out_len);
        log.log(format!("同步：Grappa token 已生成（{out_len} 字节）"));
        Some(buf)
    }
}
