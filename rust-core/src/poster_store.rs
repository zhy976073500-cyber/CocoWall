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
//! AFC (com.apple.afc.shim.remote over the RSD tunnel) is jailed to /var/mobile/Media,
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
//!   4b. DELETE: descriptors are NOT erased through the link. Each one
//!      is moved out of the store by an AirTraffic/Books sync (the
//!      Walllive-verified airlift.delete mechanism): a two-book sync
//!      (staging link + the descriptor, identified by its
//!      Airlock-escaping relative path) whose FileComplete destinations
//!      make the on-device ATAirlock daemon download the descriptor
//!      into Media as an airlift-quarantine-<token> copy. A fresh-
//!      connection commit audit must re-confirm every deleted path
//!      absent before it counts as deleted.
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
use idevice::services::lockdown::LockdownClient;
use idevice::services::rsd::RsdHandshake;
use idevice::tcp::handle::AdapterHandle;
use idevice::{Idevice, ReadWrite};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

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
/// AFC's advertised name in the RSD handshake is the shim name.
/// "com.apple.afc" is the *lockdown* service name (the one exploit
/// passes to start_service on its Lockdown route); checking the RSD
/// handshake for it always misses and falsely reports
/// serviceUnavailable — hardware log 2026-11-01 (poster_store.list,
/// run #106 build). The vendored AfcClient's RSD impl uses this same
/// shim name (idevice afc/mod.rs), and exploit's RSD route connects
/// via handshake.connect::<AfcClient>() with no other name involved.
const AFC_SERVICE: &str = "com.apple.afc.shim.remote";

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
// Delete flow — ATC manifest move (Walllive-verified mechanism)
//
// Deleting a descriptor does NOT erase it in place. Like Walllive's
// airlift.delete (full log, 2026-10-31), each descriptor is MOVED out of
// the data store by an AirTraffic/Books sync:
//
//   1. Audit (AFC listing through the staging link): confirm the target
//      descriptor is present, with stage counts logged.
//   2. Stage a zip whose symlink points at the target's descriptors/
//      directory, and write a Books.plist with exactly two books: the
//      staging link and the descriptor itself, the latter identified by
//      its Airlock-escaping relative path (the same shape as the
//      vendored canary's "target" book in exploit::run).
//   3. Run the ATC session (mirrors exploit::run's wire flow). The
//      device manifest offers device-side books for download; the host
//      then sends FileComplete per book with host-chosen destinations:
//      the link lands in Media under airlift-link-<token>, and the
//      descriptor is downloaded/moved by the on-device ATAirlock daemon
//      into Media under airlift-quarantine-<token> — out of the store.
//   4. Restore the original Books.plist; remove the staging source and
//      the link; RETAIN the quarantine copy (Walllive: stage.retained).
//   5. After all targets: commit audit on a FRESH connection — every
//      deleted path must re-audit absent before it counts as deleted.
// ---------------------------------------------------------------------------

const AIRLOCK_ROOT: &str = "/var/mobile/Media/Airlock/Book";

fn random_hex(n: usize) -> String {
    use std::io::Read;
    let mut buf = vec![0u8; n];
    let ok = std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut buf))
        .is_ok();
    if !ok {
        let seed = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0x2545f4914f6cdd1d);
        for (i, b) in buf.iter_mut().enumerate() {
            *b = ((seed >> ((i % 8) * 8)) & 0xff) as u8 ^ (i as u8);
        }
    }
    buf.iter().map(|b| format!("{b:02x}")).collect()
}

/// POSIX relative path (mirrors exploit::posix_rel).
fn posix_rel(path: &str, base: &str) -> String {
    let path_parts: Vec<&str> = path.trim_start_matches('/').split('/').collect();
    let base_parts: Vec<&str> = base.trim_start_matches('/').split('/').collect();
    let common = path_parts
        .iter()
        .zip(base_parts.iter())
        .take_while(|(a, b)| a == b)
        .count();
    let up = base_parts.len() - common;
    let down = &path_parts[common..];
    let mut rel: Vec<&str> = (0..up).map(|_| "..").chain(down.iter().copied()).collect();
    if rel.is_empty() {
        rel.push(".");
    }
    rel.join("/")
}

/// StreamingZip archive for a delete operation (mirrors
/// exploit::build_archive): META-INF + p0/p1/p2/link symlink pointing at
/// the descriptors directory + the target path components + a small
/// payload file (staged but referenced by no book — the delete sync has
/// exactly two books, link + descriptor).
fn build_delete_archive(
    descriptors_dir_abs: &str,
) -> Result<Vec<u8>, Box<dyn std::error::Error + Send + Sync>> {
    use zip::{write::FileOptions, CompressionMethod, ZipWriter};

    let target_tail = descriptors_dir_abs.trim_start_matches('/');
    let mut buf = Vec::new();
    let mut zip = ZipWriter::new(std::io::Cursor::new(&mut buf));

    use zip::write::ExtendedFileOptions;

    fn zip_opts(mode: u32) -> FileOptions<'static, ExtendedFileOptions> {
        let mut opts = FileOptions::default()
            .compression_method(CompressionMethod::Stored)
            .unix_permissions(mode);
        let mode_bytes = (mode as u16).to_le_bytes();
        let _ = opts.add_extra_data(0x5A53, Box::new(mode_bytes), false);
        opts
    }

    zip.add_directory("META-INF/", zip_opts(0o040755))?;
    zip.start_file("META-INF/com.apple.ZipMetadata.plist", zip_opts(0o100600))?;
    let meta_plist: plist::Value = {
        let mut d = plist::Dictionary::new();
        d.insert("Version".to_owned(), plist::Value::Integer(2.into()));
        plist::Value::Dictionary(d)
    };
    let mut meta_buf = Vec::new();
    plist::to_writer_binary(&mut meta_buf, &meta_plist)?;
    std::io::Write::write_all(&mut zip, &meta_buf)?;

    for dir in &["p0/", "p0/p1/", "p0/p1/p2/"] {
        zip.add_directory(*dir, zip_opts(0o040755))?;
    }

    zip.add_symlink(
        "p0/p1/p2/link",
        format!("../../../{target_tail}"),
        zip_opts(0o120777),
    )?;

    let mut cursor = String::new();
    for component in target_tail.split('/') {
        if component.is_empty() {
            continue;
        }
        cursor.push_str(component);
        cursor.push('/');
        zip.add_directory(&cursor, zip_opts(0o040755))?;
    }

    zip.start_file("payload", zip_opts(0o100600))?;
    std::io::Write::write_all(&mut zip, b"airlift delete\n")?;
    zip.finish()?;
    Ok(buf)
}

/// Books.plist sync manifest (mirrors exploit::build_books_plist).
fn build_books_plist(
    identifiers: &[String],
) -> Result<Vec<u8>, Box<dyn std::error::Error + Send + Sync>> {
    let rows: Vec<plist::Value> = identifiers
        .iter()
        .enumerate()
        .map(|(i, id)| {
            let mut d = plist::Dictionary::new();
            d.insert("Persistent ID".to_owned(), plist::Value::String(id.clone()));
            d.insert("Item ID".to_owned(), plist::Value::String((i + 1).to_string()));
            d.insert("DSID".to_owned(), plist::Value::String("1".to_owned()));
            plist::Value::Dictionary(d)
        })
        .collect();
    let mut top = plist::Dictionary::new();
    top.insert("Books".to_owned(), plist::Value::Array(rows));
    let mut buf = Vec::new();
    plist::to_writer_binary(&mut buf, &top)?;
    Ok(buf)
}

// --- ATC wire helpers (mirror exploit's AirTraffic message helpers) ---

fn atc_message_name(dict: &plist::Dictionary) -> Option<String> {
    if let Some(plist::Value::String(s)) = dict.get("Command") {
        return Some(s.clone());
    }
    if let Some(plist::Value::String(s)) = dict.get("MessageName") {
        return Some(s.clone());
    }
    None
}

fn atc_session_number(dict: &plist::Dictionary) -> Option<i64> {
    if let Some(plist::Value::Integer(n)) = dict.get("Session") {
        return n.as_signed();
    }
    if let Some(plist::Value::Integer(n)) = dict.get("SessionNumber") {
        return n.as_signed();
    }
    None
}

fn make_atc_msg(
    command: &str,
    session: i64,
    params: Option<plist::Dictionary>,
) -> plist::Dictionary {
    let mut msg = plist::Dictionary::new();
    msg.insert("Command".into(), plist::Value::String(command.into()));
    msg.insert("Session".into(), plist::Value::Integer(session.into()));
    if let Some(p) = params {
        msg.insert("Params".into(), plist::Value::Dictionary(p));
    }
    msg
}

async fn read_atc_dict<S: tokio::io::AsyncReadExt + Unpin>(
    stream: &mut S,
) -> Result<plist::Dictionary, String> {
    let mut len_buf = [0u8; 4];
    stream
        .read_exact(&mut len_buf)
        .await
        .map_err(|e| format!("read length: {e}"))?;
    let len_le = u32::from_le_bytes(len_buf) as usize;
    let len_be = u32::from_be_bytes(len_buf) as usize;
    let len = if len_le > 0 && len_le <= 10 * 1024 * 1024 {
        len_le
    } else if len_be > 0 && len_be <= 10 * 1024 * 1024 {
        len_be
    } else {
        return Err(format!(
            "ATC message length invalid: raw={:?}, le={}, be={}",
            len_buf, len_le, len_be
        ));
    };
    let mut body = vec![0u8; len];
    stream
        .read_exact(&mut body)
        .await
        .map_err(|e| format!("read body (len={len}): {e}"))?;
    let val: plist::Value = plist::from_bytes(&body).map_err(|e| format!("decode plist: {e}"))?;
    match val {
        plist::Value::Dictionary(d) => Ok(d),
        _ => Err("expected plist dictionary".into()),
    }
}

async fn send_atc_dict<S: tokio::io::AsyncWriteExt + Unpin>(
    stream: &mut S,
    dict: &plist::Dictionary,
) -> Result<(), String> {
    let mut buf = Vec::new();
    let top = plist::Value::Dictionary(dict.clone());
    plist::to_writer_binary(&mut buf, &top).map_err(|e| format!("encode plist: {e}"))?;
    let len_bytes = (buf.len() as u32).to_le_bytes();
    stream
        .write_all(&len_bytes)
        .await
        .map_err(|e| format!("write length: {e}"))?;
    stream
        .write_all(&buf)
        .await
        .map_err(|e| format!("write body: {e}"))?;
    stream
        .flush()
        .await
        .map_err(|e| format!("flush: {e}"))?;
    Ok(())
}

/// RSD service connection (mirrors exploit::connect_service_rsd: shim ->
/// bare -> Lockdown StartService fallback).
async fn connect_service_rsd(
    adapter: &mut AdapterHandle,
    handshake: &mut RsdHandshake,
    service_base: &str,
    logger: &PSLogger,
) -> Result<Box<dyn ReadWrite>, String> {
    let shim_name = format!("{service_base}.shim.remote");
    if let Some(s) = handshake.services.get(&shim_name) {
        let port = s.port;
        logger.log(format!(
            "airlift: found RSD shim service '{shim_name}' on port {port}"
        ));
        let stream = adapter
            .connect(port)
            .await
            .map_err(|e| format!("Connect to '{shim_name}' on port {port} failed: {e:?}"))?;
        let mut dev = Idevice::new(Box::new(stream), "Airlift");
        dev.rsd_checkin()
            .await
            .map_err(|e| format!("RSD checkin for '{shim_name}' failed: {e:?}"))?;
        return dev
            .get_socket()
            .ok_or_else(|| "Failed to get socket from Idevice".to_string());
    }

    if let Some(s) = handshake.services.get(service_base) {
        let port = s.port;
        logger.log(format!(
            "airlift: found RSD bare service '{service_base}' on port {port}"
        ));
        let stream = adapter
            .connect(port)
            .await
            .map_err(|e| format!("Connect to '{service_base}' on port {port} failed: {e:?}"))?;
        let mut dev = Idevice::new(Box::new(stream), "Airlift");
        dev.rsd_checkin()
            .await
            .map_err(|e| format!("RSD checkin for '{service_base}' failed: {e:?}"))?;
        return dev
            .get_socket()
            .ok_or_else(|| "Failed to get socket from Idevice".to_string());
    }

    logger.log(format!(
        "airlift: '{service_base}' not in RSD, starting via fresh Lockdown connection..."
    ));
    let mut lockdown = handshake
        .connect::<LockdownClient>(adapter)
        .await
        .map_err(|e| format!("Lockdown connect for '{service_base}' failed: {e:?}"))?;
    let (port, ssl) = lockdown
        .start_service(service_base)
        .await
        .map_err(|e| format!("Lockdown start_service('{service_base}') failed: {e:?}"))?;
    logger.log(format!(
        "airlift: '{service_base}' started on port {port} (ssl={ssl})"
    ));
    let stream = adapter
        .connect(port)
        .await
        .map_err(|e| format!("Connect to service port {port} failed: {e:?}"))?;
    Ok(Box::new(stream))
}

/// Collect (asset-id, download-flag) pairs from a device AssetManifest,
/// however deeply the asset dicts are nested.
fn collect_manifest_entries(value: &plist::Value, out: &mut Vec<(String, Option<bool>)>) {
    match value {
        plist::Value::Dictionary(d) => {
            let id = d
                .get("AssetID")
                .and_then(|v| v.as_string())
                .or_else(|| d.get("Persistent ID").and_then(|v| v.as_string()));
            if let Some(id) = id {
                let download = d.get("Download").and_then(|v| v.as_boolean());
                out.push((id.to_string(), download));
            }
            for v in d.values() {
                collect_manifest_entries(v, out);
            }
        }
        plist::Value::Array(items) => {
            for v in items {
                collect_manifest_entries(v, out);
            }
        }
        _ => {}
    }
}

// --- One delete operation (one descriptor, one ATC sync) ---

struct DeleteOpOutcome {
    link_verified: bool,
    quarantine_name: String,
    quarantine_confirmed: bool,
    descriptor_gone_local: bool,
}

async fn delete_operation(
    pairing_bytes: &[u8],
    descriptors_dir_abs: &str,
    uuid: &str,
    logger: &PSLogger,
) -> Result<DeleteOpOutcome, String> {
    let (mut adapter, mut handshake) = connect_rsd(pairing_bytes, logger)
        .await
        .map_err(|(_, msg)| msg)?;

    let mut afc = handshake
        .connect::<AfcClient>(&mut adapter)
        .await
        .map_err(|e| format!("AFC connect failed: {e:?}"))?;

    // Snapshot Books sync state (restored at the end of the operation).
    let original_books_plist = match afc.open("Books/Sync/Books.plist", AfcFopenMode::RdOnly).await {
        Ok(mut fd) => {
            let data = fd.read_entire().await.ok();
            let _ = fd.close().await;
            data
        }
        Err(_) => None,
    };

    let token = random_hex(10);
    let source = format!("airlift-src-{token}");
    let link_destination = format!("airlift-link-{token}");
    let quarantine_name = format!("airlift-quarantine-{token}");

    let descriptor_abs = format!("{descriptors_dir_abs}/{uuid}");
    let link_identifier = format!("../../{source}/p0/p1/p2/link");
    let descriptor_identifier = posix_rel(&descriptor_abs, AIRLOCK_ROOT);
    let identifiers = vec![link_identifier, descriptor_identifier.clone()];
    let destinations = vec![link_destination.clone(), quarantine_name.clone()];

    let archive = build_delete_archive(descriptors_dir_abs).map_err(|e| format!("build archive: {e}"))?;
    let books_plist = build_books_plist(&identifiers).map_err(|e| format!("build Books.plist: {e}"))?;

    // Stage via streaming_zip_conduit (mirrors exploit::run step 1).
    let mut zip_stream = connect_service_rsd(
        &mut adapter,
        &mut handshake,
        "com.apple.streaming_zip_conduit",
        logger,
    )
    .await?;
    {
        let mut zip_init_dict = plist::Dictionary::new();
        zip_init_dict.insert("MediaSubdir".to_string(), plist::Value::String(source.clone()));
        let mut init_buf = Vec::new();
        plist::to_writer_binary(&mut init_buf, &plist::Value::Dictionary(zip_init_dict))
            .map_err(|e| format!("encode MediaSubdir: {e}"))?;
        let init_len_bytes = (init_buf.len() as u32).to_be_bytes();
        zip_stream
            .write_all(&init_len_bytes)
            .await
            .map_err(|e| format!("write MediaSubdir length: {e}"))?;
        zip_stream
            .write_all(&init_buf)
            .await
            .map_err(|e| format!("write MediaSubdir body: {e}"))?;
        zip_stream.flush().await.map_err(|e| format!("flush: {e}"))?;
        zip_stream
            .write_all(&archive)
            .await
            .map_err(|e| format!("write archive bytes: {e}"))?;
        zip_stream.flush().await.map_err(|e| format!("flush: {e}"))?;
        let mut resp_len_buf = [0u8; 4];
        zip_stream
            .read_exact(&mut resp_len_buf)
            .await
            .map_err(|e| format!("read zip response length: {e}"))?;
        let resp_len = u32::from_be_bytes(resp_len_buf) as usize;
        let mut resp_body = vec![0u8; resp_len];
        zip_stream
            .read_exact(&mut resp_body)
            .await
            .map_err(|e| format!("read zip response body: {e}"))?;
    }
    drop(zip_stream);
    logger.log("airlift: airlift.delete.stage uploaded=true");

    let source_link = format!("{source}/p0/p1/p2/link");
    let source_payload = format!("{source}/payload");
    let stage_ok = afc.get_file_info(&source).await.is_ok()
        && afc.get_file_info(&source_link).await.is_ok()
        && afc.get_file_info(&source_payload).await.is_ok();
    if !stage_ok {
        return Err("stage verification failed: extracted files not present in Media".to_string());
    }

    let _ = afc.mk_dir("Airlock").await;
    let _ = afc.mk_dir("Airlock/Book").await;
    let _ = afc.mk_dir("Books").await;
    let _ = afc.mk_dir("Books/Sync").await;

    let mut books_fd = afc
        .open("Books/Sync/Books.plist", AfcFopenMode::WrOnly)
        .await
        .map_err(|e| format!("AFC open Books.plist: {e:?}"))?;
    books_fd
        .write_entire(&books_plist)
        .await
        .map_err(|e| format!("AFC write Books.plist: {e:?}"))?;
    let _ = books_fd.close().await;
    logger.log("airlift: airlift.delete.books.written=true");

    // ATC session (mirrors exploit::run step 2).
    let mut atc_stream = connect_service_rsd(&mut adapter, &mut handshake, "com.apple.atc", logger).await?;

    let mut sync_allowed = false;
    let mut session_number: i64 = 0;
    let mut grappa_info: Option<(u32, u32, u32)> = None;
    for _ in 0..12 {
        match tokio::time::timeout(
            std::time::Duration::from_millis(1500),
            read_atc_dict(&mut atc_stream),
        )
        .await
        {
            Ok(Ok(dict)) => {
                if let Some(sn) = atc_session_number(&dict) {
                    session_number = sn;
                }
                if let Some(name) = atc_message_name(&dict) {
                    logger.log(format!("airlift: atc received '{name}' (session={session_number})"));
                    if name == "Capabilities" {
                        if let Some(params) = dict.get("Params").and_then(|p| p.as_dictionary()) {
                            if let Some(gi) = params.get("GrappaSupportInfo").and_then(|g| g.as_dictionary()) {
                                let ver = gi.get("version").and_then(|v| v.as_unsigned_integer()).unwrap_or(1) as u32;
                                let dt = gi.get("deviceType").and_then(|v| v.as_unsigned_integer()).unwrap_or(0) as u32;
                                let pv = gi.get("protocolVersion").and_then(|v| v.as_unsigned_integer()).unwrap_or(1) as u32;
                                logger.log(format!("airlift: captured GrappaSupportInfo: version={ver}, deviceType={dt}, protocolVersion={pv}"));
                                grappa_info = Some((ver, dt, pv));
                            }
                        }
                    }
                    if name == "SyncAllowed" {
                        sync_allowed = true;
                        break;
                    }
                }
            }
            Ok(Err(e)) => {
                logger.log(format!("airlift: atc initial read notice: {e}"));
                break;
            }
            Err(_) => {}
        }
    }
    if sync_allowed {
        logger.log(format!("airlift: SyncAllowed observed (session={session_number})"));
    } else {
        logger.log(format!("airlift: SyncAllowed not emitted, proceeding with session={session_number}..."));
    }

    let mut host_info_dict = plist::Dictionary::new();
    host_info_dict.insert("Type".into(), plist::Value::String("iTunes".into()));
    host_info_dict.insert("Version".into(), plist::Value::String("13.7.0.161".into()));
    host_info_dict.insert("MacOSVersion".into(), plist::Value::String("15.0".into()));
    host_info_dict.insert("SyncHostName".into(), plist::Value::String("airlift".into()));
    let library_id = format!(
        "{}-{}-{}-{}-{}",
        random_hex(4),
        random_hex(2),
        random_hex(2),
        random_hex(2),
        random_hex(6)
    );
    host_info_dict.insert("LibraryID".into(), plist::Value::String(library_id));
    host_info_dict.insert(
        "SyncedDataclasses".into(),
        plist::Value::Array(vec![plist::Value::String("Book".into())]),
    );
    host_info_dict.insert(
        "SyncedAssetTypes".into(),
        plist::Value::Array(vec![plist::Value::String("Book".into())]),
    );
    host_info_dict.insert("Wakeable".into(), plist::Value::Boolean(false));

    let grappa_token = crate::grappa::generate_grappa_token(grappa_info, |s| logger.log(s));
    if let Some(ref token) = grappa_token {
        host_info_dict.insert("Grappa".into(), plist::Value::Data(token.clone()));
    }

    let mut host_info_params = plist::Dictionary::new();
    host_info_params.insert("HostInfo".into(), plist::Value::Dictionary(host_info_dict.clone()));
    host_info_params.insert("LocalCloudSupport".into(), plist::Value::Boolean(false));
    let msg_host_info = make_atc_msg("HostInfo", 0, Some(host_info_params));
    send_atc_dict(&mut atc_stream, &msg_host_info).await?;
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;

    let mut sync_req_params = plist::Dictionary::new();
    sync_req_params.insert(
        "Dataclasses".into(),
        plist::Value::Array(vec![plist::Value::String("Book".into())]),
    );
    sync_req_params.insert(
        "DataclassAnchors".into(),
        plist::Value::Dictionary(plist::Dictionary::new()),
    );
    sync_req_params.insert("HostInfo".into(), plist::Value::Dictionary(host_info_dict));
    if let Some(token) = grappa_token {
        sync_req_params.insert("Grappa".into(), plist::Value::Data(token));
    }
    let msg_sync_req = make_atc_msg("RequestingSync", 1, Some(sync_req_params));
    send_atc_dict(&mut atc_stream, &msg_sync_req).await?;

    let mut ready = false;
    for _ in 0..24 {
        match tokio::time::timeout(
            std::time::Duration::from_secs(5),
            read_atc_dict(&mut atc_stream),
        )
        .await
        {
            Ok(Ok(dict)) => {
                if let Some(name) = atc_message_name(&dict) {
                    logger.log(format!("airlift: atc sync state: '{name}'"));
                    if name == "Ping" {
                        let pong = make_atc_msg("Pong", 1, None);
                        if let Err(e) = send_atc_dict(&mut atc_stream, &pong).await {
                            logger.log(format!("airlift: pong send error: {e}"));
                            break;
                        }
                        continue;
                    }
                    if name == "ReadyForSync" || name == "AssetManifest" {
                        ready = true;
                        break;
                    }
                    if name == "SyncFailed" {
                        logger.log(format!("airlift: atc sync notice (non-fatal): {dict:?}"));
                        continue;
                    }
                }
            }
            Ok(Err(e)) => {
                logger.log(format!("airlift: atc sync read error: {e}"));
                break;
            }
            Err(_) => {}
        }
    }
    if !ready {
        return Err("AirTraffic: ReadyForSync not observed (ensure official Apple Books app is installed and opened once)".to_string());
    }
    logger.log("airlift: ReadyForSync observed");

    let mut sync_types = plist::Dictionary::new();
    sync_types.insert("Book".into(), plist::Value::Integer(1.into()));
    let mut meta_params = plist::Dictionary::new();
    meta_params.insert("SyncTypes".into(), plist::Value::Dictionary(sync_types));
    meta_params.insert(
        "DataclassAnchors".into(),
        plist::Value::Dictionary(plist::Dictionary::new()),
    );
    let msg_meta = make_atc_msg("FinishedSyncingMetadata", 1, Some(meta_params));
    send_atc_dict(&mut atc_stream, &msg_meta).await?;

    // Wait for AssetManifest and verify the device offers both books,
    // the descriptor as a download (Walllive: delete.manifest.target
    // matching_entries=1 download=true ready=true).
    let mut manifest_entries: Vec<(String, Option<bool>)> = Vec::new();
    let mut manifest_observed = false;
    for _ in 0..20 {
        match tokio::time::timeout(
            std::time::Duration::from_secs(5),
            read_atc_dict(&mut atc_stream),
        )
        .await
        {
            Ok(Ok(dict)) => {
                if let Some(name) = atc_message_name(&dict) {
                    logger.log(format!("airlift: atc manifest message: '{name}'"));
                    if name == "Ping" {
                        let pong = make_atc_msg("Pong", 1, None);
                        let _ = send_atc_dict(&mut atc_stream, &pong).await;
                        continue;
                    }
                    if name == "AssetManifest" {
                        manifest_observed = true;
                        if let Some(params) = dict.get("Params") {
                            collect_manifest_entries(params, &mut manifest_entries);
                        }
                        break;
                    }
                    if name == "SyncFailed" {
                        logger.log(format!("airlift: atc manifest notice (non-fatal): {dict:?}"));
                        continue;
                    }
                    if name == "SyncFinished" {
                        break;
                    }
                }
            }
            Ok(Err(e)) => {
                logger.log(format!("airlift: atc manifest read error: {e}"));
                break;
            }
            Err(_) => {}
        }
    }
    if !manifest_observed {
        return Err("AirTraffic: AssetManifest not observed (ensure official Apple Books app is installed)".to_string());
    }
    logger.log(format!(
        "airlift: airlift.delete.manifest book_entries={} expected={}",
        identifiers.len(),
        identifiers.len()
    ));
    for (idx, id) in identifiers.iter().enumerate() {
        let matched: Vec<&(String, Option<bool>)> = manifest_entries
            .iter()
            .filter(|(eid, _)| eid == id)
            .collect();
        let download = matched.first().and_then(|(_, d)| *d);
        logger.log(format!(
            "airlift: airlift.delete.manifest.target index={idx} matching_entries={} download={} ready={}",
            matched.len(),
            download.map(|d| d.to_string()).unwrap_or_else(|| "unknown".to_string()),
            !matched.is_empty()
        ));
        if idx == 1 && download == Some(false) {
            return Err(format!(
                "device manifest does not offer descriptor {uuid} for download; refusing to FileComplete it"
            ));
        }
    }
    logger.log("airlift: AssetManifest observed");

    // FileComplete per book, in Walllive's two phases: link first
    // (verify its Media destination), then the descriptor (the move).
    logger.log("airlift: airlift.delete.move.begin phase=link");
    logger.log("airlift: airlift.delete.asset.requested index=0");
    {
        let mut params = plist::Dictionary::new();
        params.insert("AssetID".into(), plist::Value::String(identifiers[0].clone()));
        params.insert("Dataclass".into(), plist::Value::String("Book".into()));
        params.insert("AssetPath".into(), plist::Value::String(destinations[0].clone()));
        let msg = make_atc_msg("FileComplete", 1, Some(params));
        send_atc_dict(&mut atc_stream, &msg).await?;
    }
    tokio::time::sleep(std::time::Duration::from_millis(900)).await;
    let link_verified = afc.get_file_info(&link_destination).await.is_ok();
    logger.log(format!(
        "airlift: airlift.delete.link.confirmed={} destination_verified={}",
        link_verified, link_verified
    ));

    logger.log("airlift: airlift.delete.move.begin phase=descriptor");
    logger.log("airlift: airlift.delete.asset.requested index=1");
    {
        let mut params = plist::Dictionary::new();
        params.insert("AssetID".into(), plist::Value::String(identifiers[1].clone()));
        params.insert("Dataclass".into(), plist::Value::String("Book".into()));
        params.insert("AssetPath".into(), plist::Value::String(destinations[1].clone()));
        let msg = make_atc_msg("FileComplete", 1, Some(params));
        send_atc_dict(&mut atc_stream, &msg).await?;
    }

    // Give ATAirlock time to finish moving assets (vendored settle).
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    drop(atc_stream);
    logger.log("airlift: AirTraffic sync complete");

    let quarantine_confirmed = afc.get_file_info(&quarantine_name).await.is_ok();
    logger.log(format!(
        "airlift: airlift.delete.quarantine.confirmed={} destination={}",
        quarantine_confirmed, quarantine_name
    ));

    // Local confirmation: through the freshly planted Media link (which
    // points at the descriptors directory), the descriptor must be gone.
    let descriptor_gone_local = match afc.list_dir(link_destination.clone()).await {
        Ok(names) => !names.iter().any(|n| n == uuid),
        Err(_) => false,
    };
    if descriptor_gone_local {
        logger.log("airlift: airlift.delete.descriptor.confirmed");
    }

    // Cleanup: remove staging source + link; RETAIN the quarantine copy
    // (it is the only remaining copy of the user's wallpaper data).
    let _ = afc.remove_all(&link_destination).await;
    let _ = afc.remove_all(&source).await;
    logger.log(format!(
        "airlift: airlift.delete.stage.retained quarantine={} no_read=true no_remove=true",
        quarantine_name
    ));

    // Restore original Books state (Walllive: afc.books.restore).
    let mut restored = false;
    if let Some(orig) = &original_books_plist {
        if let Ok(mut fd) = afc.open("Books/Sync/Books.plist", AfcFopenMode::WrOnly).await {
            restored = fd.write_entire(orig).await.is_ok();
            let _ = fd.close().await;
        }
    } else {
        restored = afc.remove("Books/Sync/Books.plist").await.is_ok();
    }
    logger.log(format!(
        "airlift: airlift.afc.books.restore.end verified={restored}"
    ));

    Ok(DeleteOpOutcome {
        link_verified,
        quarantine_name,
        quarantine_confirmed,
        descriptor_gone_local,
    })
}

// --- Audit helper (runs on an open store session's AFC link) ---

struct AuditOutcome {
    extensions_count: usize,
    descriptors_count: usize,
    present: bool,
}

async fn audit_target(
    afc: &mut AfcClient,
    link: &str,
    extension: &str,
    uuid: &str,
    logger: &PSLogger,
) -> AuditOutcome {
    let extensions = afc
        .list_dir(link.to_string())
        .await
        .map(visible_entries)
        .unwrap_or_default();
    let descriptors = afc
        .list_dir(format!("{link}/{extension}/descriptors"))
        .await
        .map(visible_entries)
        .unwrap_or_default();
    let present = descriptors.iter().any(|d| d == uuid);
    logger.log(format!(
        "airlift: airlift.delete.audit.listing stage=extensions complete=true count={}",
        extensions.len()
    ));
    logger.log(format!(
        "airlift: airlift.delete.audit.listing stage=descriptors complete=true count={} extension={extension}",
        descriptors.len()
    ));
    logger.log(format!(
        "airlift: airlift.delete.audit.result status={} level=descriptor",
        if present { "present" } else { "absent" }
    ));
    AuditOutcome {
        extensions_count: extensions.len(),
        descriptors_count: descriptors.len(),
        present,
    }
}

// --- Delete driver: audit -> per-target ATC move -> fresh commit audit ---

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
    logger.log("airlift: airlift.delete.begin method=atc-manifest-move");

    let pairing_bytes = std::fs::read(&pairing_path).map_err(|e| {
        (
            StoreStatus::ConnectFailed,
            format!("Failed to read pairing file at {pairing_path}: {e}"),
        )
    })?;

    let store_root = format!(
        "{}/Library/Application Support/PRBPosterExtensionDataStore/{}",
        container_path.trim_end_matches('/'),
        struct_version
    );

    // Phase A: pre-audit on one session — which targets are present?
    let mut present: Vec<bool> = Vec::new();
    {
        let mut session =
            open_store_session(&pairing_path, &container_path, struct_version, logger).await?;
        let link = session.link_name.clone();
        for (ext, uuid) in &targets {
            let audit = audit_target(&mut session.afc, &link, ext, uuid, logger).await;
            present.push(audit.present);
        }
        session.close(logger).await;
    }

    // Phase B: one ATC move operation per present target.
    struct ItemState {
        ext: String,
        uuid: String,
        was_present: bool,
        op_ok: bool,
        op_error: String,
        quarantine: String,
    }
    let mut states: Vec<ItemState> = Vec::new();
    for (idx, (ext, uuid)) in targets.iter().enumerate() {
        let mut st = ItemState {
            ext: ext.clone(),
            uuid: uuid.clone(),
            was_present: present[idx],
            op_ok: false,
            op_error: String::new(),
            quarantine: String::new(),
        };
        if !present[idx] {
            st.op_error = "not present in store at pre-audit".to_string();
            states.push(st);
            continue;
        }
        logger.log(format!(
            "airlift: airlift.delete.operation.begin target={ext}/{uuid}"
        ));
        logger.log(format!(
            "airlift: airlift.delete.target provider={ext} descriptor={uuid}"
        ));
        let descriptors_dir_abs = format!("{store_root}/Extensions/{ext}/descriptors");
        match delete_operation(&pairing_bytes, &descriptors_dir_abs, uuid, logger).await {
            Ok(outcome) => {
                // The operation's own gate is the quarantine landing;
                // whether the descriptor is truly gone is decided by the
                // fresh commit audit in phase C (descriptor_gone_local is
                // logged inside the operation as supporting evidence).
                st.op_ok = outcome.quarantine_confirmed;
                st.quarantine = outcome.quarantine_name;
                if !outcome.quarantine_confirmed {
                    st.op_error =
                        "quarantine copy not confirmed in Media after sync".to_string();
                }
            }
            Err(e) => {
                st.op_error = e;
            }
        }
        states.push(st);
    }

    // Phase C: commit audit on a FRESH connection — a target only counts
    // as deleted when its path re-audits absent (Walllive:
    // delete.commit.connection=fresh, delete.commit.audit paths=N).
    let mut commit_audit_done = false;
    let mut absent: Vec<bool> = vec![false; targets.len()];
    match open_store_session(&pairing_path, &container_path, struct_version, logger).await {
        Ok(mut session) => {
            logger.log("airlift: airlift.delete.commit.connection=fresh after_restore=true");
            let link = session.link_name.clone();
            for (idx, (ext, uuid)) in targets.iter().enumerate() {
                let audit = audit_target(&mut session.afc, &link, ext, uuid, logger).await;
                absent[idx] = !audit.present;
            }
            logger.log(format!(
                "airlift: airlift.delete.commit.audit batched=true paths={}",
                targets.len()
            ));
            session.close(logger).await;
            commit_audit_done = true;
        }
        Err((_, msg)) => {
            logger.log(format!(
                "airlift: airlift.delete.commit.audit unavailable error={msg}"
            ));
        }
    }

    let mut deleted = 0usize;
    let mut failed = 0usize;
    let mut results_json = String::new();
    for (idx, st) in states.iter().enumerate() {
        let ok = if commit_audit_done {
            st.op_ok && absent[idx]
        } else {
            // No fresh audit available: fall back to the operation's own
            // confirmations, and say so in the payload.
            st.op_ok
        };
        if ok {
            deleted += 1;
        } else {
            failed += 1;
        }
        logger.log(format!(
            "airlift: airlift.poster_store.delete.item target={}/{} ok={} error={}",
            st.ext, st.uuid, ok, st.op_error
        ));
        if idx > 0 {
            results_json.push(',');
        }
        results_json.push_str(&format!(
            "{{\"extension\":\"{}\",\"uuid\":\"{}\",\"ok\":{},\"quarantine\":\"{}\"}}",
            json_escape(&st.ext),
            json_escape(&st.uuid),
            ok,
            json_escape(&st.quarantine)
        ));
    }
    if commit_audit_done && failed == 0 {
        logger.log("airlift: airlift.delete.receipts.committed restoration_verified=true");
    }

    let json = format!(
        "{{\"deleted\":{deleted},\"failed\":{failed},\"commitAudit\":{commit_audit_done},\"results\":[{results_json}]}}"
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
            // Each target is a full ATC sync operation (~10-30s on
            // device); scale the budget with the batch size.
            let budget_secs = 240 + 120 * (targets.len() as u64);
            match tokio::time::timeout(
                Duration::from_secs(budget_secs.min(1800)),
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
                    Some("poster store delete timed out (per-target ATC budget exhausted)".to_string()),
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
