//! CocoWall core — C FFI surface consumed by the Swift app.
//!
//! Own implementation of the pairing + AirTraffic write channel used by
//! this tool class. Protocol facts and on-disk targets are documented in
//! `research/write-path.md` and `research/airlift-implementation-notes.md`.
//!
//! Status: pairing (B ring) is live — `cw_pairing_run_host` drives the
//! real RPPairing host in `pairing.rs`. The injection entries (C ring)
//! are landed: `stage.rs` stages payloads + a symlink into the Media
//! area over AFC, `atc.rs` runs the com.apple.atc Book-class sync that
//! makes the daemon write through the symlink, and `device.rs`
//! orchestrates container lookup, respring, count-verified injection,
//! and the full wallpaper apply sequence. Failures are reported with
//! the failing step's own words; nothing fakes success.
//!
//! Conventions: 0 == OK. Heap strings returned through out-params are
//! released by the caller with `cw_string_free`.

mod atc;
mod device;
mod device_log;
mod ffi_util;
mod grappa;
mod pairing;
mod stage;
mod tunnel;

use std::ffi::{c_char, c_void, CString};
use std::sync::Mutex;

use crate::device_log::Logger;

pub const CW_OK: i32 = 0;
pub const CW_ERR_FAILED: i32 = 1;
pub const CW_ERR_INVALID_ARG: i32 = 2;
pub const CW_ERR_UNIMPLEMENTED: i32 = -1;

pub type CWLogCallback = Option<extern "C" fn(ctx: *mut c_void, msg: *const c_char)>;
pub type CWPairReadyCallback = pairing::PairReadyCallback;
pub type CWPairPinCallback = pairing::PairPinCallback;
pub use pairing::CWPairResult;

// ---------------------------------------------------------------------------
// Log bridge: cw_log_init installs the Swift callback as the sink for
// `tracing` events, so pairing/tunnel progress is visible on device.
// ---------------------------------------------------------------------------

struct LogSink {
    cb: CWLogCallback,
    ctx: usize,
}
// The callback + ctx are owned by the Swift caller for the app's lifetime.
unsafe impl Send for LogSink {}

static LOG_SINK: Mutex<Option<LogSink>> = Mutex::new(None);

pub(crate) fn log_line(msg: &str) {
    if let Ok(guard) = LOG_SINK.lock() {
        if let Some(sink) = guard.as_ref() {
            if let Some(cb) = sink.cb {
                if let Ok(c) = CString::new(msg) {
                    cb(sink.ctx as *mut c_void, c.as_ptr());
                }
            }
        }
    }
}

mod log_bridge {
    use std::fmt::Write as _;
    use std::sync::atomic::{AtomicU64, Ordering};
    use tracing::field::{Field, Visit};
    use tracing::{Event, Id, Level, Metadata, Subscriber};

    /// Minimal tracing subscriber: formats each event's message and
    /// forwards it to the Swift log callback. Spans are not tracked —
    /// the FFI only needs the flat progress lines.
    pub struct CallbackSubscriber;

    static NEXT_SPAN: AtomicU64 = AtomicU64::new(1);

    struct MsgVisitor(String);

    impl Visit for MsgVisitor {
        fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
            if field.name() == "message" {
                let _ = write!(self.0, "{value:?}");
            } else {
                let _ = write!(self.0, " {}={value:?}", field.name());
            }
        }
    }

    impl Subscriber for CallbackSubscriber {
        fn enabled(&self, metadata: &Metadata<'_>) -> bool {
            metadata.level() <= &Level::INFO
        }
        fn new_span(&self, _attrs: &tracing::span::Attributes<'_>) -> Id {
            Id::from_u64(NEXT_SPAN.fetch_add(1, Ordering::Relaxed))
        }
        fn record(&self, _span: &Id, _values: &tracing::span::Record<'_>) {}
        fn record_follows_from(&self, _span: &Id, _follows: &Id) {}
        fn event(&self, event: &Event<'_>) {
            let mut visitor = MsgVisitor(String::new());
            event.record(&mut visitor);
            crate::log_line(&visitor.0);
        }
        fn enter(&self, _span: &Id) {}
        fn exit(&self, _span: &Id) {}
    }
}

fn set_out(slot: *mut *mut c_char, value: &str) {
    if slot.is_null() {
        return;
    }
    if let Ok(s) = CString::new(value) {
        unsafe { *slot = s.into_raw() };
    }
}

// ---------------------------------------------------------------------------
// Version / strings / logging
// ---------------------------------------------------------------------------

/// Link canary: a static, NUL-terminated version string. Do NOT free.
#[no_mangle]
pub extern "C" fn cw_core_version() -> *const c_char {
    static VERSION: &str = concat!(
        "cocowall-core ",
        env!("CARGO_PKG_VERSION"),
        " · idevice 0.1.68\0"
    );
    VERSION.as_ptr() as *const c_char
}

#[no_mangle]
pub extern "C" fn cw_string_free(p: *mut c_char) {
    if !p.is_null() {
        unsafe { drop(CString::from_raw(p)) };
    }
}

#[no_mangle]
pub extern "C" fn cw_log_init(cb: CWLogCallback, ctx: *mut c_void) -> i32 {
    if let Ok(mut guard) = LOG_SINK.lock() {
        *guard = Some(LogSink { cb, ctx: ctx as usize });
    }
    // One-shot: a second call only replaces the sink, never re-installs.
    let _ = tracing::subscriber::set_global_default(log_bridge::CallbackSubscriber);
    CW_OK
}

// ---------------------------------------------------------------------------
// Pairing — RPPairing host (iOS 27+ on-device route), real implementation
// in pairing.rs. Blocking: call from a background thread.
// ---------------------------------------------------------------------------

#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub extern "C" fn cw_pairing_run_host(
    bind_addr: *const c_char,
    port: u16,
    name: *const c_char,
    model: *const c_char,
    out_path: *const c_char,
    host_alt_irk_hex: *const c_char,
    ready_cb: CWPairReadyCallback,
    pin_cb: CWPairPinCallback,
    ctx: *mut c_void,
    out: *mut CWPairResult,
) -> i32 {
    unsafe {
        pairing::run_host(
            bind_addr, port, name, model, out_path, host_alt_irk_hex, ready_cb, pin_cb, ctx, out,
        )
    }
}

#[no_mangle]
pub extern "C" fn cw_pairing_result_free(r: *mut CWPairResult) {
    unsafe { pairing::result_free(r) }
}

// ---------------------------------------------------------------------------
// Write channel — C ring (injection), implemented in device.rs /
// stage.rs / atc.rs. All entries are blocking; call from a background
// thread. Log lines stream through the caller-provided callback.
// ---------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn cw_exploit_run(
    pairing_path: *const c_char,
    _target: *const c_char,
    log_cb: CWLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing = ffi_util::opt_str(pairing_path, "");
    if pairing.is_empty() {
        set_out(out_error, "pairing_path 为空（尚未配对）");
        return CW_ERR_INVALID_ARG;
    }
    let logger = Logger::new(log_cb, ctx);
    match ffi_util::run_async("cw_exploit_run", async move { device::canary(&pairing, &logger).await }) {
        Ok(Ok(json)) => {
            set_out(out_json, &json);
            CW_OK
        }
        Ok(Err(e)) => {
            set_out(out_error, &e);
            CW_ERR_FAILED
        }
        Err(e) => {
            set_out(out_error, &e);
            CW_ERR_FAILED
        }
    }
}

#[no_mangle]
pub extern "C" fn cw_exploit_write_dir(
    pairing_path: *const c_char,
    source_dir: *const c_char,
    target_dir: *const c_char,
    log_cb: CWLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing = ffi_util::opt_str(pairing_path, "");
    let source = ffi_util::opt_str(source_dir, "");
    let target = ffi_util::opt_str(target_dir, "");
    if pairing.is_empty() || source.is_empty() || target.is_empty() {
        set_out(out_error, "pairing_path / source_dir / target_dir 不能为空");
        return CW_ERR_INVALID_ARG;
    }
    let logger = Logger::new(log_cb, ctx);
    let source_path = std::path::PathBuf::from(&source);
    match ffi_util::run_async("cw_exploit_write_dir", async move {
        device::write_dir(&pairing, &source_path, &target, &logger).await
    }) {
        Ok(Ok(())) => CW_OK,
        Ok(Err(e)) => {
            set_out(out_error, &e);
            CW_ERR_FAILED
        }
        Err(e) => {
            set_out(out_error, &e);
            CW_ERR_FAILED
        }
    }
}

#[no_mangle]
pub extern "C" fn cw_exploit_inject_folder(
    pairing_path: *const c_char,
    folder_path: *const c_char,
    target_parent_dir: *const c_char,
    dest_name: *const c_char,
    log_cb: CWLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing = ffi_util::opt_str(pairing_path, "");
    let folder = ffi_util::opt_str(folder_path, "");
    let target = ffi_util::opt_str(target_parent_dir, "");
    let dest = ffi_util::opt_str(dest_name, "");
    if pairing.is_empty() || folder.is_empty() || target.is_empty() || dest.is_empty() {
        set_out(
            out_error,
            "pairing_path / folder_path / target_parent_dir / dest_name 不能为空",
        );
        return CW_ERR_INVALID_ARG;
    }
    let logger = Logger::new(log_cb, ctx);
    let folder_pathbuf = std::path::PathBuf::from(&folder);
    match ffi_util::run_async("cw_exploit_inject_folder", async move {
        device::inject_folder(&pairing, &folder_pathbuf, &target, &dest, &logger).await
    }) {
        Ok(Ok(_outcome)) => CW_OK,
        Ok(Err(e)) => {
            set_out(out_error, &e);
            CW_ERR_FAILED
        }
        Err(e) => {
            set_out(out_error, &e);
            CW_ERR_FAILED
        }
    }
}

#[no_mangle]
pub extern "C" fn cw_find_app_container(
    pairing_path: *const c_char,
    bundle_id: *const c_char,
    log_cb: CWLogCallback,
    ctx: *mut c_void,
    out_container: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing = ffi_util::opt_str(pairing_path, "");
    let bundle = ffi_util::opt_str(bundle_id, "");
    if pairing.is_empty() || bundle.is_empty() {
        set_out(out_error, "pairing_path / bundle_id 不能为空");
        return CW_ERR_INVALID_ARG;
    }
    let logger = Logger::new(log_cb, ctx);
    match ffi_util::run_async("cw_find_app_container", async move {
        device::find_container(&pairing, &bundle, &logger).await
    }) {
        Ok(Ok(container)) => {
            set_out(out_container, &container);
            CW_OK
        }
        Ok(Err(e)) => {
            set_out(out_error, &e);
            CW_ERR_FAILED
        }
        Err(e) => {
            set_out(out_error, &e);
            CW_ERR_FAILED
        }
    }
}

#[no_mangle]
pub extern "C" fn cw_device_respring(
    pairing_path: *const c_char,
    log_cb: CWLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing = ffi_util::opt_str(pairing_path, "");
    if pairing.is_empty() {
        set_out(out_error, "pairing_path 为空（尚未配对）");
        return CW_ERR_INVALID_ARG;
    }
    let logger = Logger::new(log_cb, ctx);
    match ffi_util::run_async("cw_device_respring", async move {
        device::respring(&pairing, &logger).await
    }) {
        Ok(Ok(())) => CW_OK,
        Ok(Err(e)) => {
            set_out(out_error, &e);
            CW_ERR_FAILED
        }
        Err(e) => {
            set_out(out_error, &e);
            CW_ERR_FAILED
        }
    }
}

/// Full wallpaper apply for one descriptor folder: container lookup,
/// staging-copy prep (new UUID + identifier rewrite), primary inject,
/// iOS 18+ dual inject, refresh plist. On success `out_report` is a
/// JSON object; respring stays a separate explicit step.
#[no_mangle]
pub extern "C" fn cw_wallpaper_apply(
    pairing_path: *const c_char,
    descriptor_dir: *const c_char,
    log_cb: CWLogCallback,
    ctx: *mut c_void,
    out_report: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing = ffi_util::opt_str(pairing_path, "");
    let descriptor = ffi_util::opt_str(descriptor_dir, "");
    if pairing.is_empty() || descriptor.is_empty() {
        set_out(out_error, "pairing_path / descriptor_dir 不能为空");
        return CW_ERR_INVALID_ARG;
    }
    let logger = Logger::new(log_cb, ctx);
    let descriptor_path = std::path::PathBuf::from(&descriptor);
    match ffi_util::run_async("cw_wallpaper_apply", async move {
        device::apply_wallpaper(&pairing, &descriptor_path, &logger).await
    }) {
        Ok(Ok(report)) => {
            let json = serde_json::json!({
                "uuid": report.uuid,
                "identifierRewritten": report.identifier_rewritten,
                "primaryBefore": report.primary_before,
                "primaryAfter": report.primary_after,
                "dual": report.dual,
                "productVersion": report.product_version,
            })
            .to_string();
            set_out(out_report, &json);
            CW_OK
        }
        Ok(Err(e)) => {
            set_out(out_error, &e);
            CW_ERR_FAILED
        }
        Err(e) => {
            set_out(out_error, &e);
            CW_ERR_FAILED
        }
    }
}

// ---------------------------------------------------------------------------
// Target host configuration (tunnel.rs keeps the value; default 10.7.0.1)
// ---------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn cw_set_target_host(host: *const c_char) -> i32 {
    let value = ffi_util::opt_str(host, "");
    tunnel::set_target_host(if value.is_empty() { None } else { Some(value) });
    CW_OK
}

#[no_mangle]
pub extern "C" fn cw_clear_target_hosts() {
    tunnel::set_target_host(None);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;
    use std::sync::Mutex as StdMutex;

    #[test]
    fn version_string_is_present() {
        let p = cw_core_version();
        assert!(!p.is_null());
        let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap();
        assert!(s.contains(env!("CARGO_PKG_VERSION")), "version: {s}");
    }

    static CAPTURED: StdMutex<Vec<String>> = StdMutex::new(Vec::new());

    extern "C" fn capture_cb(_ctx: *mut c_void, msg: *const c_char) {
        if msg.is_null() {
            return;
        }
        let s = unsafe { CStr::from_ptr(msg) }.to_string_lossy().into_owned();
        CAPTURED.lock().unwrap().push(s);
    }

    #[test]
    fn log_init_forwards_tracing_events() {
        assert_eq!(cw_log_init(Some(capture_cb), std::ptr::null_mut()), CW_OK);
        tracing::info!("pairing probe line");
        let captured = CAPTURED.lock().unwrap();
        assert!(
            captured.iter().any(|l| l.contains("pairing probe line")),
            "captured: {captured:?}"
        );
    }
}
