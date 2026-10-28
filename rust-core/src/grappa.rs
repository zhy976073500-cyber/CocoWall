//! Grappa token generation for the AirTraffic sync handshake.
//!
//! The token is produced on the device at runtime by `ALGetGrappaToken`,
//! a small Objective-C helper compiled into the app
//! (Sources/App/GrappaHelper.m) that drives the device's private
//! AirTraffic frameworks and hands the bytes back through this C
//! interface.
//!
//! Why a direct link instead of the previous dlsym(RTLD_DEFAULT)
//! lookup: the helper was compiled into the app all along, but a
//! main-executable symbol that nothing references at link time is
//! internalised by the Darwin linker (it ends up as a private-external
//! symtab entry and is absent from the export trie — verified by
//! parsing the shipped run #23 binary: 2672 exported symbols, none of
//! them `_ALGetGrappaToken`). dlsym can therefore never resolve it and
//! the on-device log reported "symbol not found" while the code sat in
//! the binary unused. Declaring the function as a plain extern and
//! calling it makes the link itself guarantee the helper is present:
//! if it ever drops out of the app target, the build fails loudly
//! instead of the sync silently degrading on device.
//!
//! Absence of a token is still reported, never papered over: when the
//! helper cannot produce one it returns non-zero with a step-by-step
//! diagnostic trace, which is logged verbatim below.

use std::ffi::CStr;

extern "C" {
    /// Implemented by Sources/App/GrappaHelper.m in the app target.
    /// `diag_buf` receives a step trace on success and failure alike.
    fn ALGetGrappaToken(
        in_version: u32,
        in_device_type: u32,
        in_protocol_version: u32,
        out_buf: *mut u8,
        max_len: usize,
        out_len: *mut usize,
        diag_buf: *mut libc::c_char,
        diag_len: usize,
    ) -> libc::c_int;
}

/// Ask the in-app helper for a Grappa client token. `device_info`
/// carries the (version, deviceType, protocolVersion) triple reported
/// by the daemon in its Capabilities message; defaults to (1, 0, 1).
pub fn generate_grappa_token(
    device_info: Option<(u32, u32, u32)>,
    log: &crate::device_log::Logger,
) -> Option<Vec<u8>> {
    let (ver, dt, pv) = device_info.unwrap_or((1, 0, 1));
    log.log(format!(
        "同步：Grappa 第 1 步——调用 App 内 GrappaHelper 的 ALGetGrappaToken（静态链接直调；入参 version={ver} deviceType={dt} protocolVersion={pv}，来源：{})",
        if device_info.is_some() {
            "守护进程 Capabilities 的 GrappaSupportInfo"
        } else {
            "默认值（守护进程未给出 GrappaSupportInfo）"
        }
    ));

    let mut buf = vec![0u8; 512];
    let mut out_len: usize = 0;
    let mut diag_buf = [0 as libc::c_char; 1024];
    let rc = unsafe {
        ALGetGrappaToken(
            ver,
            dt,
            pv,
            buf.as_mut_ptr(),
            buf.len(),
            &mut out_len,
            diag_buf.as_mut_ptr(),
            diag_buf.len(),
        )
    };

    let diag = unsafe { CStr::from_ptr(diag_buf.as_ptr()) }.to_string_lossy();
    if !diag.is_empty() {
        log.log(format!("同步：GrappaHelper 步骤记录：{diag}"));
    }

    if rc != 0 || out_len == 0 {
        log.log(format!(
            "同步：Grappa token 生成失败（rc={rc}，out_len={out_len}），本次同步将不带 Grappa 字段"
        ));
        return None;
    }
    buf.truncate(out_len);
    log.log(format!(
        "同步：Grappa 第 2 步——token 已生成（{out_len} 字节）"
    ));
    Some(buf)
}
