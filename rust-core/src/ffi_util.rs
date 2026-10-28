//! Small helpers shared by the FFI entry points: C string conversion and
//! running blocking work on a fat-stack worker thread (FFI callers on iOS
//! often sit on threads with small stacks, and the device stack's async
//! machinery is not stack-frugal).

use std::ffi::{c_char, CStr, CString};

/// Read an optional C string, falling back to `default` for null/invalid.
pub fn opt_str(p: *const c_char, default: &str) -> String {
    if p.is_null() {
        return default.to_owned();
    }
    unsafe { CStr::from_ptr(p) }
        .to_str()
        .unwrap_or(default)
        .to_owned()
}

/// Heap-allocate a C string the caller releases with `cw_string_free`.
pub fn cstr(s: impl std::fmt::Display) -> *mut c_char {
    let s = format!("{s}");
    CString::new(s)
        .unwrap_or_else(|_| CString::new("(invalid utf-8)").unwrap())
        .into_raw()
}

/// Run `f` on a dedicated thread with a large stack and block on its
/// result, converting panics into error strings instead of unwinding
/// across the FFI boundary.
pub fn run_blocking<F, R>(name: &str, f: F) -> Result<R, String>
where
    F: FnOnce() -> R + Send + 'static,
    R: Send + 'static,
{
    std::thread::Builder::new()
        .name(name.to_string())
        .stack_size(8 * 1024 * 1024)
        .spawn(f)
        .map_err(|e| format!("failed to spawn worker '{name}': {e}"))?
        .join()
        .map_err(|e| format!("worker '{name}' panicked: {e:?}"))
}

/// Build a fresh multi-thread Tokio runtime and block on `fut`.
pub fn block_on<F, R>(fut: F) -> Result<R, String>
where
    F: std::future::Future<Output = R>,
{
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("failed to build tokio runtime: {e}"))?;
    Ok(rt.block_on(fut))
}

/// Combined helper: fat-stack thread + Tokio runtime, for FFI entries.
pub fn run_async<F, R>(name: &str, fut: F) -> Result<R, String>
where
    F: std::future::Future<Output = R> + Send + 'static,
    R: Send + 'static,
{
    run_blocking(name, move || {
        block_on(fut).expect("runtime construction cannot fail twice")
    })
}
