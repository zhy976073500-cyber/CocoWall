//! CocoWall core — C FFI surface consumed by the Swift app.
//!
//! Own implementation of the pairing + AirTraffic write channel used by
//! this tool class. Protocol facts and on-disk targets are documented in
//! `research/write-path.md` and `research/airlift-implementation-notes.md`.
//!
//! Status: pairing (B ring) is live — `cw_pairing_run_host` drives the
//! real RPPairing host in `pairing.rs`. The injection entries (C ring:
//! stage + AirTraffic sync in `stage.rs` / `atc.rs` / `device.rs`) are
//! NOT landed yet and return `CW_ERR_UNIMPLEMENTED` with a message that
//! says so; they never fake success.
//!
//! Conventions: 0 == OK. Heap strings returned through out-params are
//! released by the caller with `cw_string_free`.

mod device_log;
mod ffi_util;
mod grappa;
mod pairing;
mod tunnel;

use std::ffi::{c_char, c_void, CString};
use std::sync::Mutex;

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

/// C-ring (injection) entries share this honest failure until stage/atc
/// land: distinct code, and the message names the missing ring in plain
/// words so the UI shows exactly what is not there yet.
fn inject_not_landed(what: &str, out_error: *mut *mut c_char) -> i32 {
    set_out(
        out_error,
        &format!("注入环未落地：{what} 尚未实现（AFC 暂存 + AirTraffic 同步层未编入本构建）"),
    );
    CW_ERR_UNIMPLEMENTED
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
// Write channel — C ring (injection), NOT landed yet. Every entry fails
// honestly with CW_ERR_UNIMPLEMENTED and a message naming the missing
// ring; nothing here pretends a write happened.
// ---------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn cw_exploit_run(
    _pairing_path: *const c_char,
    _target: *const c_char,
    _log_cb: CWLogCallback,
    _ctx: *mut c_void,
    _out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    inject_not_landed("cw_exploit_run（通道探活）", out_error)
}

#[no_mangle]
pub extern "C" fn cw_exploit_write_dir(
    _pairing_path: *const c_char,
    _source_dir: *const c_char,
    _target_dir: *const c_char,
    _log_cb: CWLogCallback,
    _ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    inject_not_landed("cw_exploit_write_dir（整目录写入）", out_error)
}

#[no_mangle]
pub extern "C" fn cw_exploit_inject_folder(
    _pairing_path: *const c_char,
    _folder_path: *const c_char,
    _target_parent_dir: *const c_char,
    _dest_name: *const c_char,
    _log_cb: CWLogCallback,
    _ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    inject_not_landed("cw_exploit_inject_folder（文件夹注入）", out_error)
}

#[no_mangle]
pub extern "C" fn cw_find_app_container(
    _pairing_path: *const c_char,
    _bundle_id: *const c_char,
    _log_cb: CWLogCallback,
    _ctx: *mut c_void,
    _out_container: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    inject_not_landed("cw_find_app_container（容器定位）", out_error)
}

#[no_mangle]
pub extern "C" fn cw_device_respring(
    _pairing_path: *const c_char,
    _log_cb: CWLogCallback,
    _ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    inject_not_landed("cw_device_respring（设备重启）", out_error)
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
