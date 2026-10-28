//! RPPairing host — the iOS 27+ on-device pairing route.
//!
//! Flow: bind a TCP listener, hand the Bonjour service details to Swift
//! through the ready callback (Swift publishes them with NetService, which
//! needs no multicast entitlement), wait for the device to connect back,
//! then drive idevice's PairableHost handshake. The PIN is generated
//! host-side and surfaced through the pin callback; the user types it into
//! Settings › Privacy & Security › Developer Mode › Pair with CocoWall.
//! On success the RPPairing file is persisted at `out_path` and reused by
//! every later device operation.

use std::ffi::{c_char, c_void, CString};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::ptr;

use idevice::remote_pairing::{PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket};
use tokio::net::TcpListener;

use crate::ffi_util::{cstr, opt_str, run_async};

pub type PairReadyCallback = Option<
    extern "C" fn(
        ctx: *mut c_void,
        service_id: *const c_char,
        port: u16,
        txt_keys: *const *const c_char,
        txt_vals: *const *const c_char,
        txt_count: usize,
    ),
>;

pub type PairPinCallback = Option<extern "C" fn(pin: *const c_char, ctx: *mut c_void)>;

#[repr(C)]
pub struct CWPairResult {
    pub error: *mut c_char,
    pub device_name: *mut c_char,
    pub device_udid: *mut c_char,
    pub pairing_file_path: *mut c_char,
    pub host_alt_irk_hex: *mut c_char,
}

impl CWPairResult {
    fn empty() -> Self {
        Self {
            error: ptr::null_mut(),
            device_name: ptr::null_mut(),
            device_udid: ptr::null_mut(),
            pairing_file_path: ptr::null_mut(),
            host_alt_irk_hex: ptr::null_mut(),
        }
    }
}

struct Callbacks {
    ready: PairReadyCallback,
    pin: PairPinCallback,
    ctx: usize,
}
unsafe impl Send for Callbacks {}

/// # Safety
/// All `*const c_char` args must be null or valid C strings; `out` must
/// point to a writable CWPairResult owned by the caller.
#[allow(clippy::too_many_arguments)]
pub unsafe fn run_host(
    bind_addr: *const c_char,
    port: u16,
    name: *const c_char,
    model: *const c_char,
    out_path: *const c_char,
    host_alt_irk_hex: *const c_char,
    ready_cb: PairReadyCallback,
    pin_cb: PairPinCallback,
    ctx: *mut c_void,
    out: *mut CWPairResult,
) -> i32 {
    if out.is_null() {
        return 2;
    }
    *out = CWPairResult::empty();

    let cbs = Callbacks { ready: ready_cb, pin: pin_cb, ctx: ctx as usize };
    let bind_addr = opt_str(bind_addr, "0.0.0.0");
    let name = opt_str(name, "CocoWall");
    let model = opt_str(model, "Mac17,7");
    let out_path = opt_str(out_path, "pairing.plist");
    let saved_irk = parse_alt_irk(&opt_str(host_alt_irk_hex, ""));

    let res = run_async("cw_pairing_run_host", async move {
        async_run_host(bind_addr, port, name, model, out_path, saved_irk, cbs).await
    });

    match res {
        Ok(Ok((dev_name, udid, path, irk_hex))) => {
            (*out).device_name = cstr(dev_name);
            (*out).device_udid = cstr(udid);
            (*out).pairing_file_path = cstr(path);
            (*out).host_alt_irk_hex = cstr(irk_hex);
            0
        }
        Ok(Err(e)) => {
            (*out).error = cstr(e);
            1
        }
        Err(panic_msg) => {
            (*out).error = cstr(panic_msg);
            1
        }
    }
}

async fn async_run_host(
    bind_addr: String,
    port: u16,
    name: String,
    model: String,
    out_path: String,
    saved_alt_irk: Option<[u8; 16]>,
    cbs: Callbacks,
) -> Result<(String, String, String, String), String> {
    tracing::info!("pairing: binding listener on {bind_addr}:{port}");
    let ip: IpAddr = bind_addr.parse().unwrap_or(IpAddr::V4(Ipv4Addr::UNSPECIFIED));
    let listener = TcpListener::bind(SocketAddr::new(ip, port))
        .await
        .map_err(|e| format!("配对监听绑定失败 {bind_addr}:{port}: {e}"))?;
    let bound_port = listener
        .local_addr()
        .map_err(|e| format!("无法读取监听地址: {e}"))?
        .port();
    tracing::info!("pairing: listening on port {bound_port}");

    // Reuse the host key pair from a previous run when one exists so the
    // device keeps recognising this host; the stored device altIRK is for
    // the *previous* peer session and must not leak into a fresh accept.
    let mut pairing_file = match RpPairingFile::read_from_file(&out_path).await {
        Ok(mut existing) => {
            existing.alt_irk = None;
            tracing::info!("pairing: reusing host key pair from {out_path}");
            existing
        }
        Err(_) => {
            tracing::info!("pairing: generating a new host key pair");
            RpPairingFile::generate(&name)
        }
    };

    let mut host_info = PairableHostInfo::generate(&name, &model);
    if let Some(irk) = saved_alt_irk {
        host_info.alt_irk = irk;
        tracing::info!("pairing: reusing stored host altIRK");
    }
    let host_alt_irk = host_info.alt_irk;
    let service_id = pairing_file.identifier.clone();

    emit_ready(&cbs, &service_id, bound_port, &host_info);

    tracing::info!("pairing: waiting for the device to connect…");
    let (stream, peer_addr) = listener
        .accept()
        .await
        .map_err(|e| format!("接受设备连接失败: {e}"))?;
    tracing::info!("pairing: device connected from {peer_addr}");

    let socket = RpPairingSocket::new_device(stream);
    let mut host = PairableHost::new(socket, host_info);

    let pin_cb = cbs.pin;
    let pin_ctx = cbs.ctx;
    let peer_info = host
        .accept(&mut pairing_file, move |pin| {
            let pin_cb = pin_cb;
            async move {
                tracing::info!("pairing: PIN issued");
                if let Some(cb) = pin_cb {
                    if let Ok(c) = CString::new(pin.as_str()) {
                        cb(c.as_ptr(), pin_ctx as *mut c_void);
                    }
                }
            }
        })
        .await
        .map_err(|e| format!("配对握手失败: {e:?}"))?;
    tracing::info!("pairing: handshake complete — {} ({})", peer_info.name, peer_info.model);

    pairing_file
        .write_to_file(&out_path)
        .await
        .map_err(|e| format!("配对文件写入失败: {e}"))?;
    let size = tokio::fs::metadata(&out_path).await.map(|m| m.len()).unwrap_or(0);
    if size == 0 {
        return Err(format!("握手完成但配对文件 {out_path} 为空"));
    }
    tracing::info!("pairing: pairing file written to {out_path} ({size} bytes)");

    Ok((
        peer_info.name,
        peer_info.remotepairing_udid,
        out_path,
        bytes_to_hex(&host_alt_irk),
    ))
}

/// # Safety
/// `r` must be null or a CWPairResult populated by `run_host`.
pub unsafe fn result_free(r: *mut CWPairResult) {
    if r.is_null() {
        return;
    }
    for p in [
        (*r).error,
        (*r).device_name,
        (*r).device_udid,
        (*r).pairing_file_path,
        (*r).host_alt_irk_hex,
    ] {
        if !p.is_null() {
            drop(CString::from_raw(p));
        }
    }
    *r = CWPairResult::empty();
}

fn emit_ready(cbs: &Callbacks, service_id: &str, port: u16, host_info: &PairableHostInfo) {
    let Some(cb) = cbs.ready else { return };
    let records = host_info.mdns_txt_records(service_id);
    let keys: Vec<CString> = records.iter().map(|(k, _)| CString::new(k.as_str()).unwrap_or_default()).collect();
    let vals: Vec<CString> = records.iter().map(|(_, v)| CString::new(v.as_str()).unwrap_or_default()).collect();
    let key_ptrs: Vec<*const c_char> = keys.iter().map(|s| s.as_ptr()).collect();
    let val_ptrs: Vec<*const c_char> = vals.iter().map(|s| s.as_ptr()).collect();
    let Ok(id_c) = CString::new(service_id) else { return };
    cb(cbs.ctx as *mut c_void, id_c.as_ptr(), port, key_ptrs.as_ptr(), val_ptrs.as_ptr(), records.len());
}

fn parse_alt_irk(s: &str) -> Option<[u8; 16]> {
    if s.len() != 32 {
        return None;
    }
    let mut out = [0u8; 16];
    for (i, b) in out.iter_mut().enumerate() {
        *b = u8::from_str_radix(s.get(i * 2..i * 2 + 2)?, 16).ok()?;
    }
    Some(out)
}

fn bytes_to_hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}
