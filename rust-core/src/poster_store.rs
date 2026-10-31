//! PosterBoard data-store enumeration + cleanup (device-side "already
//! imported" wallpapers) — the detect/cleanup feature behind the
//! 「检测本机已导入的壁纸」 button on the Wallpapers tab.
//!
//! LOCAL ADDITION — not part of the vendored AirCard-iOS upstream core.
//! Registered in rust-core/VENDORED.md and SPEC.md (2026-11-01).
//!
//! Why this channel: the flash flow reaches the PosterBoard data store
//! only through ATC sync (Books dataclass), which is write-only from the
//! host's point of view — it cannot list or delete what is already in the
//! store. The store itself is a plain directory tree inside the
//! PosterBoard PluginKit container:
//!
//!   <container>/Library/Application Support/
//!     PRBPosterExtensionDataStore/<version>/Extensions/
//!       <extension-id>/descriptors/<UUID>/…
//!
//! AFC (com.apple.afc over the RSD tunnel) is jailed to /var/mobile/Media,
//! but it follows symlinks planted inside the jail — that is exactly how
//! the flash staging works (a symlink in Media pointing at the store's
//! descriptors directory, created by the staged zip). This module plants
//! the same kind of link directly with the AFC MakeLink operation:
//!
//!   1. Open an RSD tunnel (same idevice_ffi tunnel_provider primitives
//!      and host strategy as poster_refresh::connect_rsd: last working
//!      route first, then the known loopback-VPN gateway defaults;
//!      RemoteXPC with raw RPPairing fallback per host).
//!   2. Connect the AFC service from the RSD handshake.
//!   3. Plant a temporary symlink `cocowall-store-<token>` at the Media
//!      root pointing at the store's Extensions directory.
//!   4a. LIST: enumerate extension dirs, then each `descriptors/` dir;
//!      per descriptor read the small identifier text file and walk
//!      versions/<v>/contents/ for the `<name>.wallpaper` package name
//!      (readable-name priority: package name > identifier > UUID).
//!   4b. DELETE: remove_all each selected descriptor directory through
//!      the link, then re-count the affected descriptors dirs.
//!   5. Remove the temporary symlink (best effort, always).
//!
//! Results come back as JSON in an out parameter, with a machine-readable
//! status string like the other FFIs. Failures are reported, never
//! disguised: if AFC refuses the link or the traversal, the status says
//! so and no list is fabricated.

use std::ffi::{c_char, c_void, CString};
use std::time::{Duration, Instant};

use idevice::afc::opcode::{AfcFopenMode, LinkType};
use idevice::afc::AfcClient;
use idevice::remote_pairing::RpPairingFile;
use idevice::services::rsd::RsdHandshake;
use idevice::tcp::handle::AdapterHandle;

use crate::exploit::{CachedRouteMode, ALLogCallback};
use crate::ffi_util::{cstr, opt_str};

// ---------------------------------------------------------------------------
// Logger (same shape as poster_refresh::PRLogger)
// ---------------------------------------------------------------------------

struct PSLogger {
    cb: ALLogCallback,
    ctx: *mut c_void,
}
unsafe impl Send for PSLogger {}
unsafe impl Sync for PSLogger {}

impl PSLogger {
    fn log(&self, msg: impl AsRef<str>) {
        let s = msg.as_ref();
        tracing::info!("{s}");
        if let Some(cb) = self.cb {
            if let Ok(c) = CString::new(s) {
                cb(self.ctx, c.as_ptr());
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StoreStatus {
    Ok,
    Partial,
    ConnectFailed,
    ServiceUnavailable,
    StageFailed,
    ListFailed,
    AfcFailed,
}

impl StoreStatus {
    fn as_str(&self) -> &'static str {
        match self {
            StoreStatus::Ok => "ok",
            StoreStatus::Partial => "partial",
            StoreStatus::ConnectFailed => "connectFailed",
            StoreStatus::ServiceUnavailable => "serviceUnavailable",
            StoreStatus::StageFailed => "stageFailed",
            StoreStatus::ListFailed => "listFailed",
            StoreStatus::AfcFailed => "afcFailed",
        }
    }
}

type StoreResult<T> = Result<T, (StoreStatus, String)>;

const RSD_PORT: u16 = 49152;
const AFC_SERVICE: &str = "com.apple.afc";

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

/// Random-enough token for the temporary symlink name (uniqueness is all
/// that matters; the link lives for one call and is removed afterwards).
fn random_token() -> String {
    let mut seed = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0x9e3779b97f4a7c15)
        ^ ((std::process::id() as u128) << 64);
    let mut out = String::with_capacity(24);
    for _ in 0..12 {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        out.push_str(&format!("{:02x}", (seed & 0xff) as u8));
    }
    out
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn extensions_abs(container_path: &str, struct_version: i64) -> String {
    format!(
        "{}/Library/Application Support/PRBPosterExtensionDataStore/{}/Extensions",
        container_path.trim_end_matches('/'),
        struct_version
    )
}

// ---------------------------------------------------------------------------
// RSD tunnel (RSD-only mirror of poster_refresh::connect_rsd; AFC is used
// over the RSD route here so the same connection also carries the pairing
// file's Remote Pairing credentials)
// ---------------------------------------------------------------------------

async fn connect_rsd(
    pairing_bytes: &[u8],
    logger: &PSLogger,
) -> Result<(AdapterHandle, RsdHandshake), (StoreStatus, String)> {
    if RpPairingFile::from_bytes(pairing_bytes).is_err() {
        return Err((
            StoreStatus::ServiceUnavailable,
            "pairing file carries no Remote Pairing credentials; the RSD route is required"
                .to_string(),
        ));
    }

    let mut hosts: Vec<String> = Vec::new();
    let cached = crate::exploit::get_last_working_route();
    if let Some(route) = &cached {
        if matches!(
            route.mode,
            CachedRouteMode::RsdRemoteXpc | CachedRouteMode::RsdRawRpPairing
        ) && !route.host.trim().is_empty()
        {
            hosts.push(route.host.clone());
        }
    }
    for fb in ["10.7.0.1", "10.7.0.2", "10.7.0.3", "10.0.0.1", "172.16.0.1"] {
        if !hosts.iter().any(|h| h == fb) {
            hosts.push(fb.to_string());
        }
    }
    let extra_hosts: Vec<std::net::IpAddr> = hosts
        .iter()
        .filter_map(|s| s.parse::<std::net::IpAddr>().ok())
        .filter(|ip| !ip.is_loopback())
        .collect();

    let mut last_err = String::new();

    if let Some(route) = &cached {
        if matches!(
            route.mode,
            CachedRouteMode::RsdRemoteXpc | CachedRouteMode::RsdRawRpPairing
        ) {
            if let Ok(ip) = route.host.parse::<std::net::Ipv4Addr>() {
                let socket_addr = std::net::SocketAddr::new(std::net::IpAddr::V4(ip), RSD_PORT);
                let extra = vec![std::net::IpAddr::V4(ip)];
                let mut rpf = RpPairingFile::from_bytes(pairing_bytes)
                    .map_err(|e| (StoreStatus::ConnectFailed, format!("{e:?}")))?;
                let attempt = match route.mode {
                    CachedRouteMode::RsdRawRpPairing => {
                        tokio::time::timeout(
                            Duration::from_millis(2000),
                            idevice_ffi::tunnel_provider::tunnel_create_rppairing_multihost_async(
                                socket_addr,
                                "Airlift",
                                &mut rpf,
                                &extra,
                            ),
                        )
                        .await
                    }
                    _ => {
                        tokio::time::timeout(
                            Duration::from_millis(2000),
                            idevice_ffi::tunnel_provider::tunnel_create_remotexpc_multihost_async(
                                socket_addr,
                                "Airlift",
                                &mut rpf,
                                &extra,
                            ),
                        )
                        .await
                    }
                };
                match attempt {
                    Ok(Ok(pair)) => {
                        logger.log(format!(
                            "airlift: poster_store tunnel connected via cached route on {}:{RSD_PORT}",
                            route.host
                        ));
                        return Ok(pair);
                    }
                    Ok(Err(failure)) => {
                        last_err = format!("cached {}:{RSD_PORT}: {:?}", route.host, failure.kind);
                    }
                    Err(_) => {
                        last_err = format!("cached {}:{RSD_PORT}: timed out", route.host);
                    }
                }
            }
        }
    }

    for ip_str in &hosts {
        let Ok(ip) = ip_str.parse::<std::net::Ipv4Addr>() else { continue };
        if ip.is_loopback() {
            continue;
        }
        let socket_addr = std::net::SocketAddr::new(std::net::IpAddr::V4(ip), RSD_PORT);

        let mut rpf = match RpPairingFile::from_bytes(pairing_bytes) {
            Ok(r) => r,
            Err(e) => {
                return Err((StoreStatus::ConnectFailed, format!("pairing parse: {e:?}")));
            }
        };
        match tokio::time::timeout(
            Duration::from_millis(2500),
            idevice_ffi::tunnel_provider::tunnel_create_remotexpc_multihost_async(
                socket_addr,
                "Airlift",
                &mut rpf,
                &extra_hosts,
            ),
        )
        .await
        {
            Ok(Ok(pair)) => {
                logger.log(format!(
                    "airlift: poster_store tunnel connected on {ip_str}:{RSD_PORT} via RemoteXPC"
                ));
                crate::exploit::set_last_working_route(crate::exploit::CachedRoute {
                    host: ip_str.clone(),
                    mode: CachedRouteMode::RsdRemoteXpc,
                });
                return Ok(pair);
            }
            Ok(Err(failure)) => {
                last_err = format!("{ip_str}:{RSD_PORT}: {:?} ({:?})", failure.error, failure.kind);
                if failure.kind
                    != idevice_ffi::tunnel_provider::TunnelFailureKind::TunnelFailureRsdUnreachable
                {
                    let mut rpf2 = match RpPairingFile::from_bytes(pairing_bytes) {
                        Ok(r) => r,
                        Err(e) => {
                            return Err((
                                StoreStatus::ConnectFailed,
                                format!("pairing parse: {e:?}"),
                            ));
                        }
                    };
                    match tokio::time::timeout(
                        Duration::from_millis(2500),
                        idevice_ffi::tunnel_provider::tunnel_create_rppairing_multihost_async(
                            socket_addr,
                            "Airlift",
                            &mut rpf2,
                            &extra_hosts,
                        ),
                    )
                    .await
                    {
                        Ok(Ok(pair)) => {
                            logger.log(format!(
                                "airlift: poster_store tunnel connected on {ip_str}:{RSD_PORT} via raw RPPairing"
                            ));
                            crate::exploit::set_last_working_route(crate::exploit::CachedRoute {
                                host: ip_str.clone(),
                                mode: CachedRouteMode::RsdRawRpPairing,
                            });
                            return Ok(pair);
                        }
                        Ok(Err(raw_failure)) => {
                            last_err = format!("{ip_str}:{RSD_PORT}: {:?}", raw_failure.kind);
                        }
                        Err(_) => {
                            last_err = format!("{ip_str}:{RSD_PORT}: raw RPPairing timed out");
                        }
                    }
                }
            }
            Err(_) => {
                last_err = format!("{ip_str}:{RSD_PORT}: RemoteXPC timed out");
            }
        }
    }

    Err((StoreStatus::ConnectFailed, last_err))
}

// ---------------------------------------------------------------------------
// AFC session with the staging symlink planted
// ---------------------------------------------------------------------------

struct StoreSession {
    afc: AfcClient,
    link_name: String,
}

async fn open_store_session(
    pairing_path: &str,
    container_path: &str,
    struct_version: i64,
    logger: &PSLogger,
) -> StoreResult<StoreSession> {
    let pairing_bytes = std::fs::read(pairing_path).map_err(|e| {
        (
            StoreStatus::ConnectFailed,
            format!("Failed to read pairing file at {pairing_path}: {e}"),
        )
    })?;

    let (mut adapter, mut handshake) = connect_rsd(&pairing_bytes, logger).await?;

    let advertised = handshake.services.contains_key(AFC_SERVICE);
    logger.log(format!(
        "airlift: airlift.poster_store.service advertised={advertised} service={AFC_SERVICE}"
    ));
    if !advertised {
        return Err((
            StoreStatus::ServiceUnavailable,
            format!("{AFC_SERVICE} not advertised by RSD handshake"),
        ));
    }

    let mut afc = handshake
        .connect::<AfcClient>(&mut adapter)
        .await
        .map_err(|e| {
            (
                StoreStatus::ServiceUnavailable,
                format!("AFC connect failed: {e:?}"),
            )
        })?;
    logger.log("airlift: airlift.poster_store.afc connected=true");

    // Plant the staging symlink at the Media root pointing at the store's
    // Extensions directory (absolute target inside the PosterBoard
    // container — same reach the flash staging link has).
    let target = extensions_abs(container_path, struct_version);
    let link_name = format!("cocowall-store-{}", random_token());
    afc.link(target.clone(), link_name.clone(), LinkType::Symlink)
        .await
        .map_err(|e| {
            (
                StoreStatus::StageFailed,
                format!("AFC MakeLink (symlink -> {target}) failed: {e:?}"),
            )
        })?;
    logger.log(format!(
        "airlift: airlift.poster_store.link.staged name={link_name} target={target}"
    ));

    // Verify the link resolves before trusting any listing through it.
    match afc.list_dir(link_name.clone()).await {
        Ok(_) => {
            logger.log("airlift: airlift.poster_store.link.traversable=true");
        }
        Err(e) => {
            let _ = afc.remove(link_name.clone()).await;
            return Err((
                StoreStatus::ListFailed,
                format!(
                    "AFC cannot list through the staging symlink (target {target}): {e:?}"
                ),
            ));
        }
    }

    Ok(StoreSession { afc, link_name })
}

impl StoreSession {
    async fn close(mut self, logger: &PSLogger) {
        match self.afc.remove(self.link_name.clone()).await {
            Ok(()) => logger.log("airlift: airlift.poster_store.link.removed=true"),
            Err(e) => logger.log(format!(
                "airlift: airlift.poster_store.link.removed=false error={e:?}"
            )),
        }
    }
}

async fn read_small_file(afc: &mut AfcClient, path: &str) -> Option<String> {
    let mut fd = afc.open(path.to_string(), AfcFopenMode::RdOnly).await.ok()?;
    let bytes = fd.read_entire().await.ok()?;
    let _ = fd.close().await;
    if bytes.is_empty() || bytes.len() > 4096 {
        return None;
    }
    String::from_utf8(bytes)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn visible_entries(mut names: Vec<String>) -> Vec<String> {
    names.retain(|n| n != "." && n != ".." && !n.is_empty());
    names.sort();
    names
}

// ---------------------------------------------------------------------------
// List flow
// ---------------------------------------------------------------------------

async fn store_list(
    pairing_path: String,
    container_path: String,
    struct_version: i64,
    logger: &PSLogger,
) -> StoreResult<String> {
    let started = Instant::now();
    logger.log("airlift: airlift.poster_store.list.begin");

    let mut session = open_store_session(&pairing_path, &container_path, struct_version, logger).await?;
    let link = session.link_name.clone();

    let result = enumerate_descriptors(&mut session.afc, &link, logger).await;
    session.close(logger).await;

    let items = result?;
    let mut json = String::from("{\"items\":[");
    for (i, item) in items.iter().enumerate() {
        if i > 0 {
            json.push(',');
        }
        json.push_str(&format!(
            "{{\"extension\":\"{}\",\"uuid\":\"{}\",\"identifier\":\"{}\",\"packageName\":\"{}\",\"name\":\"{}\"}}",
            json_escape(&item.extension),
            json_escape(&item.uuid),
            json_escape(&item.identifier),
            json_escape(&item.package_name),
            json_escape(&item.name),
        ));
    }
    json.push_str("]}");
    logger.log(format!(
        "airlift: airlift.poster_store.list.end count={} duration_ms={}",
        items.len(),
        started.elapsed().as_millis()
    ));
    Ok(json)
}

struct DescriptorItem {
    extension: String,
    uuid: String,
    identifier: String,
    package_name: String,
    name: String,
}

async fn enumerate_descriptors(
    afc: &mut AfcClient,
    link: &str,
    logger: &PSLogger,
) -> StoreResult<Vec<DescriptorItem>> {
    let extensions = visible_entries(afc.list_dir(link.to_string()).await.map_err(|e| {
        (
            StoreStatus::ListFailed,
            format!("listing Extensions through the staging symlink failed: {e:?}"),
        )
    })?);
    logger.log(format!(
        "airlift: airlift.poster_store.extensions.found count={} names={}",
        extensions.len(),
        extensions.join(",")
    ));

    let mut items: Vec<DescriptorItem> = Vec::new();
    for ext in &extensions {
        let desc_dir = format!("{link}/{ext}/descriptors");
        let uuids = match afc.list_dir(desc_dir).await {
            Ok(names) => visible_entries(names),
            Err(e) => {
                logger.log(format!(
                    "airlift: airlift.poster_store.descriptors.unreadable extension={ext} error={e:?}"
                ));
                continue;
            }
        };
        logger.log(format!(
            "airlift: airlift.poster_store.descriptors.found extension={ext} count={}",
            uuids.len()
        ));
        for uuid in uuids {
            let base = format!("{link}/{ext}/descriptors/{uuid}");
            let identifier = read_small_file(
                afc,
                &format!("{base}/com.apple.posterkit.provider.descriptor.identifier"),
            )
            .await
            .unwrap_or_default();

            // Package name: versions/<v>/contents/<name>.wallpaper
            let mut package_name = String::new();
            if let Ok(versions) = afc.list_dir(format!("{base}/versions")).await {
                for version in visible_entries(versions) {
                    if let Ok(contents) =
                        afc.list_dir(format!("{base}/versions/{version}/contents")).await
                    {
                        if let Some(pkg) = visible_entries(contents)
                            .into_iter()
                            .find(|n| n.ends_with(".wallpaper"))
                        {
                            package_name =
                                pkg.trim_end_matches(".wallpaper").to_string();
                            break;
                        }
                    }
                }
            }

            let name = if !package_name.is_empty() {
                package_name.clone()
            } else if !identifier.is_empty() {
                identifier.clone()
            } else {
                uuid.chars().take(8).collect()
            };
            items.push(DescriptorItem {
                extension: ext.clone(),
                uuid,
                identifier,
                package_name,
                name,
            });
        }
    }
    Ok(items)
}

// ---------------------------------------------------------------------------
// Delete flow
// ---------------------------------------------------------------------------

async fn store_delete(
    pairing_path: String,
    container_path: String,
    struct_version: i64,
    targets: Vec<(String, String)>,
    logger: &PSLogger,
) -> StoreResult<(String, bool)> {
    let started = Instant::now();
    logger.log(format!(
        "airlift: airlift.poster_store.delete.begin targets={}",
        targets.len()
    ));

    let mut session = open_store_session(&pairing_path, &container_path, struct_version, logger).await?;
    let link = session.link_name.clone();

    let mut deleted = 0usize;
    let mut failed = 0usize;
    let mut results_json = String::new();
    let mut affected_exts: Vec<String> = Vec::new();

    for (idx, (ext, uuid)) in targets.iter().enumerate() {
        if !affected_exts.contains(ext) {
            affected_exts.push(ext.clone());
        }
        let path = format!("{link}/{ext}/descriptors/{uuid}");
        let (ok, error_text) = match session.afc.remove_all(path).await {
            Ok(()) => (true, String::new()),
            Err(e) => (false, format!("{e:?}")),
        };
        if ok {
            deleted += 1;
        } else {
            failed += 1;
        }
        logger.log(format!(
            "airlift: airlift.poster_store.delete.item target={ext}/{uuid} ok={ok} error={error_text}"
        ));
        if idx > 0 {
            results_json.push(',');
        }
        results_json.push_str(&format!(
            "{{\"extension\":\"{}\",\"uuid\":\"{}\",\"ok\":{}}}",
            json_escape(ext),
            json_escape(uuid),
            ok
        ));
    }

    // Re-count the affected descriptors dirs so the log (and the caller's
    // re-list) can confirm removal took effect in the store.
    for ext in &affected_exts {
        match session.afc.list_dir(format!("{link}/{ext}/descriptors")).await {
            Ok(names) => logger.log(format!(
                "airlift: airlift.poster_store.delete.remaining extension={ext} count={}",
                visible_entries(names).len()
            )),
            Err(e) => logger.log(format!(
                "airlift: airlift.poster_store.delete.remaining extension={ext} error={e:?}"
            )),
        }
    }

    session.close(logger).await;

    let json = format!(
        "{{\"deleted\":{deleted},\"failed\":{failed},\"results\":[{results_json}]}}"
    );
    logger.log(format!(
        "airlift: airlift.poster_store.delete.end deleted={deleted} failed={failed} duration_ms={}",
        started.elapsed().as_millis()
    ));
    Ok((json, failed > 0))
}

// ---------------------------------------------------------------------------
// FFI entries (shape mirrors poster_refresh::poster_refresh)
// ---------------------------------------------------------------------------

unsafe fn write_outs(
    out_json: *mut *mut c_char,
    out_status: *mut *mut c_char,
    out_error: *mut *mut c_char,
    json: Option<&str>,
    status: StoreStatus,
    error: Option<&str>,
) {
    if !out_json.is_null() {
        if let Some(j) = json {
            *out_json = cstr(j);
        }
    }
    if !out_status.is_null() {
        *out_status = cstr(status.as_str());
    }
    if !out_error.is_null() {
        if let Some(e) = error {
            *out_error = cstr(e);
        }
    }
}

/// # Safety
/// All pointer args must be null or valid for their documented types.
/// `out_json` / `out_status` / `out_error` receive heap strings owned by
/// the caller (free with al_string_free) when non-null.
pub unsafe fn poster_store_list(
    pairing_path: *const c_char,
    container_path: *const c_char,
    struct_version: i64,
    log_cb: ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_status: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let container_path = opt_str(container_path, "");
    let ctx_usize = ctx as usize;

    let res = crate::ffi_util::run_with_large_stack("al_poster_store_list", move || {
        let logger = PSLogger { cb: log_cb, ctx: ctx_usize as *mut c_void };
        idevice_ffi::run_sync_local(async move {
            match tokio::time::timeout(
                Duration::from_secs(120),
                store_list(pairing_path, container_path, struct_version, &logger),
            )
            .await
            {
                Ok(Ok(json)) => (Some(json), StoreStatus::Ok, None),
                Ok(Err((status, message))) => {
                    logger.log(format!(
                        "airlift: airlift.poster_store.list.end status={} error={message}",
                        status.as_str()
                    ));
                    (None, status, Some(message))
                }
                Err(_) => (
                    None,
                    StoreStatus::AfcFailed,
                    Some("poster store list timed out after 120s".to_string()),
                ),
            }
        })
    });

    let (json, status, error) = match res {
        Ok(triple) => triple,
        Err(panic_msg) => (None, StoreStatus::ConnectFailed, Some(panic_msg)),
    };
    write_outs(out_json, out_status, out_error, json.as_deref(), status, error.as_deref());
    if status == StoreStatus::Ok {
        0
    } else {
        1
    }
}

/// # Safety
/// Same contract as poster_store_list. `targets_csv` is a comma-separated
/// list of "<extension-id>/<descriptor-uuid>" entries to delete.
pub unsafe fn poster_store_delete(
    pairing_path: *const c_char,
    container_path: *const c_char,
    struct_version: i64,
    targets_csv: *const c_char,
    log_cb: ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_status: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let container_path = opt_str(container_path, "");
    let targets_raw = opt_str(targets_csv, "");
    let ctx_usize = ctx as usize;

    let targets: Vec<(String, String)> = targets_raw
        .split(',')
        .filter_map(|entry| {
            let entry = entry.trim();
            let (ext, uuid) = entry.split_once('/')?;
            if ext.is_empty() || uuid.is_empty() {
                None
            } else {
                Some((ext.to_string(), uuid.to_string()))
            }
        })
        .collect();

    let res = crate::ffi_util::run_with_large_stack("al_poster_store_delete", move || {
        let logger = PSLogger { cb: log_cb, ctx: ctx_usize as *mut c_void };
        idevice_ffi::run_sync_local(async move {
            if targets.is_empty() {
                return (
                    None,
                    StoreStatus::AfcFailed,
                    Some("no valid delete targets supplied".to_string()),
                );
            }
            match tokio::time::timeout(
                Duration::from_secs(180),
                store_delete(pairing_path, container_path, struct_version, targets, &logger),
            )
            .await
            {
                Ok(Ok((json, had_failures))) => (
                    Some(json),
                    if had_failures { StoreStatus::Partial } else { StoreStatus::Ok },
                    None,
                ),
                Ok(Err((status, message))) => {
                    logger.log(format!(
                        "airlift: airlift.poster_store.delete.end status={} error={message}",
                        status.as_str()
                    ));
                    (None, status, Some(message))
                }
                Err(_) => (
                    None,
                    StoreStatus::AfcFailed,
                    Some("poster store delete timed out after 180s".to_string()),
                ),
            }
        })
    });

    let (json, status, error) = match res {
        Ok(triple) => triple,
        Err(panic_msg) => (None, StoreStatus::ConnectFailed, Some(panic_msg)),
    };
    write_outs(out_json, out_status, out_error, json.as_deref(), status, error.as_deref());
    if matches!(status, StoreStatus::Ok | StoreStatus::Partial) {
        0
    } else {
        1
    }
}
