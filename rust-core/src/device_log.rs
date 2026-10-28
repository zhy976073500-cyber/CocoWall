//! Per-call logger: forwards human-readable progress lines to the Swift
//! side through the C log callback (and to tracing for good measure).
//! The segmented apply-flow log in the app is fed from here, one line per
//! sub-step, so on-device failures show exactly which segment broke.

use std::ffi::{c_char, c_void, CString};

pub type LogCallback = Option<extern "C" fn(ctx: *mut c_void, msg: *const c_char)>;

#[derive(Clone, Copy)]
pub struct Logger {
    cb: LogCallback,
    ctx: usize,
}

// The callback context is owned by the Swift caller, which guarantees it
// outlives the FFI call; sending the pointer across our worker thread is
// therefore sound.
unsafe impl Send for Logger {}
unsafe impl Sync for Logger {}

impl Logger {
    pub fn new(cb: LogCallback, ctx: *mut c_void) -> Self {
        Self { cb, ctx: ctx as usize }
    }

    pub fn log(&self, msg: impl AsRef<str>) {
        let s = msg.as_ref();
        tracing::info!("{s}");
        if let Some(cb) = self.cb {
            if let Ok(c) = CString::new(s) {
                cb(self.ctx as *mut c_void, c.as_ptr());
            }
        }
    }
}
