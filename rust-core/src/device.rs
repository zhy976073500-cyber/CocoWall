//! Device operations behind the FFI surface: the canary probe,
//! PosterBoard container lookup, respring, folder/file injection via
//! AFC staging + AirTraffic sync, and the full wallpaper apply
//! sequence (descriptor prep → primary inject → iOS 18+ dual inject →
//! PosterBoard refresh plist). Protocol facts are recorded in
//! research/airlift-implementation-notes.md and research/write-path.md;
//! this file is an independent implementation of them.

use std::path::{Path, PathBuf};

use idevice::services::afc::AfcClient;

use crate::atc::AtcSession;
use crate::device_log::Logger;
use crate::stage::{self, StagedSync};
use crate::tunnel::{connect_tunnel, DeviceTunnel};

pub const POSTERBOARD_BUNDLE_ID: &str = "com.apple.PosterBoard";
/// PRBPosterExtensionDataStore structure version on iOS 17 and later.
pub const STORE_VERSION: &str = "61";
pub const COLLECTIONS_EXT: &str = "com.apple.WallpaperKit.CollectionsPoster";
pub const MODERN_COLLECTIONS_EXT: &str = "com.apple.Posters.CollectionsPosterApp";
const REFRESH_PLIST_NAME: &str = "com.apple.PosterBoard.unprotectedUserDefaults.plist";

async fn read_pairing(pairing_path: &str) -> Result<Vec<u8>, String> {
    std::fs::read(pairing_path)
        .map_err(|e| format!("读取配对文件 {pairing_path} 失败: {e}（请先完成本机配对）"))
}

async fn open_tunnel(pairing_path: &str, log: &Logger) -> Result<DeviceTunnel, String> {
    let bytes = read_pairing(pairing_path).await?;
    connect_tunnel(&bytes, log).await
}

// ---------------------------------------------------------------------------
// Canary probe
// ---------------------------------------------------------------------------

/// Prove the channel works without touching any system state: tunnel
/// up, an AFC write/read/remove roundtrip in Media, and the AirTraffic
/// daemon accepting a connection. Returns a JSON status object.
pub async fn canary(pairing_path: &str, log: &Logger) -> Result<String, String> {
    let mut tunnel = open_tunnel(pairing_path, log).await?;
    let route = tunnel.route_name().to_string();

    let mut afc = tunnel.connect_afc(log).await?;
    let probe = "cocowall-canary-probe.txt";
    let payload = b"cocowall canary";
    stage::afc_write_file(&mut afc, probe, payload).await?;
    let back = stage::afc_read_file(&mut afc, probe)
        .await
        .ok_or_else(|| "金丝雀探针：AFC 回读失败".to_string())?;
    if back != payload {
        return Err("金丝雀探针：AFC 回读内容不一致".to_string());
    }
    let _ = afc.remove(probe).await;
    log.log("金丝雀探针：AFC 读写往返成功".to_string());

    // The AirTraffic daemon accepting the connection is the last
    // front-door signal; a full handshake is the inject path's job.
    let _session = AtcSession::connect(&mut tunnel, log).await?;
    log.log("金丝雀探针：com.apple.atc 可连接".to_string());

    Ok(serde_json::json!({
        "route": route,
        "afcRoundtrip": true,
        "atcConnected": true,
    })
    .to_string())
}

// ---------------------------------------------------------------------------
// Container lookup / respring
// ---------------------------------------------------------------------------

async fn container_via(
    tunnel: &mut DeviceTunnel,
    bundle_id: &str,
    log: &Logger,
) -> Result<String, String> {
    let mut proxy = tunnel.connect_installation_proxy(log).await?;
    let apps = proxy
        .get_apps(Some("Any"), Some(vec![bundle_id.to_string()]))
        .await
        .map_err(|e| format!("InstallationProxy 查询 {bundle_id} 失败: {e:?}"))?;
    let app = apps
        .get(bundle_id)
        .ok_or_else(|| format!("设备上没有应用 {bundle_id}"))?;
    let dict = app
        .as_dictionary()
        .ok_or_else(|| format!("{bundle_id} 的应用信息不是字典"))?;
    let container = dict
        .get("Container")
        .and_then(|v| v.as_string())
        .ok_or_else(|| format!("{bundle_id} 的应用信息缺少 Container"))?;
    Ok(container.replace("/private/var/", "/var/"))
}

pub async fn find_container(
    pairing_path: &str,
    bundle_id: &str,
    log: &Logger,
) -> Result<String, String> {
    let mut tunnel = open_tunnel(pairing_path, log).await?;
    container_via(&mut tunnel, bundle_id, log).await
}

pub async fn respring(pairing_path: &str, log: &Logger) -> Result<(), String> {
    let mut tunnel = open_tunnel(pairing_path, log).await?;
    let mut diag = tunnel.connect_diagnostics(log).await?;
    diag.restart()
        .await
        .map_err(|e| format!("DiagnosticsRelay 重启失败: {e:?}"))?;
    log.log("设备重启（respring）指令已发送".to_string());
    Ok(())
}

// ---------------------------------------------------------------------------
// Staged sync driver (shared by folder inject and file writes)
// ---------------------------------------------------------------------------

pub struct SyncOutcome {
    pub before_count: usize,
    pub after_count: usize,
}

/// Drive one staged sync: ATC handshake, FileComplete for the link,
/// read the target listing through the landed symlink, FileComplete
/// for the payload(s), settle, then verify every expected name is
/// present in the target and the count actually moved for new names.
/// A target that cannot be read back through the symlink is reported
/// as failure — an unverified inject is never called a success.
async fn run_staged_sync(
    tunnel: &mut DeviceTunnel,
    afc: &mut AfcClient,
    staged: &StagedSync,
    expected_names: &[String],
    log: &Logger,
) -> Result<SyncOutcome, String> {
    let mut atc = AtcSession::connect(tunnel, log).await?;
    let grappa_info = atc.wait_sync_allowed(log).await?;
    atc.handshake(grappa_info, log).await?;

    // 1) The symlink asset first: it lands at the Media root.
    atc.file_complete(&staged.identifiers[0], &staged.destinations[0], log)
        .await?;
    tokio::time::sleep(std::time::Duration::from_millis(900)).await;

    // Read the target directory through the symlink.
    let before = match stage::list_dir_names(afc, &staged.link_destination).await {
        Ok(names) => names,
        Err(_) => {
            tokio::time::sleep(std::time::Duration::from_millis(1500)).await;
            stage::list_dir_names(afc, &staged.link_destination).await.map_err(|e| {
                format!(
                    "计数校验失败：无法经 symlink 回读目标目录（{e}）——注入结果未确认，按失败处理"
                )
            })?
        }
    };
    log.log(format!(
        "校验：同步前目标目录共 {} 项",
        before.len()
    ));

    // 2) The payload asset(s), through the symlink.
    for i in 1..staged.identifiers.len() {
        atc.file_complete(&staged.identifiers[i], &staged.destinations[i], log)
            .await?;
        if i + 1 < staged.identifiers.len() {
            tokio::time::sleep(std::time::Duration::from_millis(900)).await;
        }
    }
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;

    let after = stage::list_dir_names(afc, &staged.link_destination).await?;
    log.log(format!(
        "校验：同步后目标目录共 {} 项",
        after.len()
    ));
    for name in expected_names {
        if !after.iter().any(|n| n == name) {
            return Err(format!(
                "计数校验失败：目标目录中没有出现 '{name}'（同步前 {} 项、同步后 {} 项）",
                before.len(),
                after.len()
            ));
        }
        if !before.iter().any(|n| n == name) && after.len() <= before.len() {
            return Err(format!(
                "计数校验失败：'{name}' 为新条目但目录计数未增加（{} → {}）",
                before.len(),
                after.len()
            ));
        }
    }
    Ok(SyncOutcome {
        before_count: before.len(),
        after_count: after.len(),
    })
}

/// Stage + sync + cleanup + Books.plist restore for one folder.
async fn inject_folder_via(
    tunnel: &mut DeviceTunnel,
    folder: &Path,
    target_parent_dir: &str,
    dest_name: &str,
    log: &Logger,
) -> Result<SyncOutcome, String> {
    let mut afc = tunnel.connect_afc(log).await?;
    let original_books = stage::snapshot_books_plist(&mut afc).await;

    let result = async {
        let staged =
            stage::stage_folder(tunnel, &mut afc, folder, target_parent_dir, dest_name, log)
                .await?;
        let outcome = run_staged_sync(
            tunnel,
            &mut afc,
            &staged,
            &[dest_name.to_string()],
            log,
        )
        .await;
        stage::cleanup_stage(&mut afc, &staged).await;
        outcome
    }
    .await;

    stage::restore_books_plist(&mut afc, &original_books).await;
    result
}

pub async fn inject_folder(
    pairing_path: &str,
    folder: &Path,
    target_parent_dir: &str,
    dest_name: &str,
    log: &Logger,
) -> Result<SyncOutcome, String> {
    let mut tunnel = open_tunnel(pairing_path, log).await?;
    inject_folder_via(&mut tunnel, folder, target_parent_dir, dest_name, log).await
}

/// Stage + sync + cleanup + restore for a set of in-memory files.
async fn write_files_via(
    tunnel: &mut DeviceTunnel,
    files: &[(String, Vec<u8>)],
    target_dir: &str,
    log: &Logger,
) -> Result<SyncOutcome, String> {
    let mut afc = tunnel.connect_afc(log).await?;
    let original_books = stage::snapshot_books_plist(&mut afc).await;

    let result = async {
        let staged = stage::stage_files(tunnel, &mut afc, files, target_dir, log).await?;
        let expected: Vec<String> = files.iter().map(|(n, _)| n.clone()).collect();
        let outcome = run_staged_sync(tunnel, &mut afc, &staged, &expected, log).await;
        stage::cleanup_stage(&mut afc, &staged).await;
        outcome
    }
    .await;

    stage::restore_books_plist(&mut afc, &original_books).await;
    result
}

/// Write every regular file directly inside `source_dir` (dotfiles
/// skipped, non-recursive) into `target_dir`.
pub async fn write_dir(
    pairing_path: &str,
    source_dir: &Path,
    target_dir: &str,
    log: &Logger,
) -> Result<(), String> {
    let mut files: Vec<(String, Vec<u8>)> = Vec::new();
    let entries = std::fs::read_dir(source_dir)
        .map_err(|e| format!("读取源目录 {} 失败: {e}", source_dir.display()))?;
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with('.') {
            continue;
        }
        let bytes = std::fs::read(&path)
            .map_err(|e| format!("读取文件 {} 失败: {e}", path.display()))?;
        files.push((name, bytes));
    }
    if files.is_empty() {
        return Err(format!(
            "源目录 {} 里没有可写入的文件",
            source_dir.display()
        ));
    }
    let mut tunnel = open_tunnel(pairing_path, log).await?;
    write_files_via(&mut tunnel, &files, target_dir, log)
        .await
        .map(|_| ())
}

// ---------------------------------------------------------------------------
// Wallpaper apply sequence
// ---------------------------------------------------------------------------

fn copy_dir_recursive(src: &Path, dst: &Path) -> Result<(), String> {
    std::fs::create_dir_all(dst)
        .map_err(|e| format!("创建暂存目录 {} 失败: {e}", dst.display()))?;
    let entries = std::fs::read_dir(src)
        .map_err(|e| format!("读取 descriptor {} 失败: {e}", src.display()))?;
    for entry in entries.flatten() {
        let path = entry.path();
        let target = dst.join(entry.file_name());
        if path.is_dir() {
            copy_dir_recursive(&path, &target)?;
        } else if path.is_file() {
            std::fs::copy(&path, &target)
                .map_err(|e| format!("复制 {} 失败: {e}", path.display()))?;
        }
    }
    Ok(())
}

fn collect_files(dir: &Path, out: &mut Vec<PathBuf>) {
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                collect_files(&path, out);
            } else if path.is_file() {
                out.push(path);
            }
        }
    }
}

/// The descriptor identifier rewrite, applied to a staging copy: when
/// the package carries suggestion metadata the identifiers are already
/// consistent and nothing is touched; otherwise a fresh random 5-digit
/// ID replaces the old one in the descriptor.identifier text (only
/// when it is a pure integer), in contents.userInfo's
/// wallpaperRepresentingIdentifier, and in every Wallpaper.plist's
/// identifier. Returns true when anything was rewritten.
fn rewrite_descriptor_identifiers(dir: &Path, new_id: u32, log: &Logger) -> bool {
    if dir
        .join("com.apple.posterkit.provider.identifierURL.suggestionMetadata.plist")
        .exists()
    {
        log.log("壁纸准备：包内带 suggestionMetadata，标识符保持原样".to_string());
        return false;
    }
    let mut files = Vec::new();
    collect_files(dir, &mut files);
    let mut rewritten = false;
    for path in files {
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();
        if name.starts_with('.') {
            continue;
        }
        match name.as_str() {
            "com.apple.posterkit.provider.descriptor.identifier" => {
                if let Ok(content) = std::fs::read_to_string(&path) {
                    if content.trim().parse::<i64>().is_ok() {
                        if std::fs::write(&path, new_id.to_string()).is_ok() {
                            rewritten = true;
                        }
                    }
                }
            }
            "com.apple.posterkit.provider.contents.userInfo" => {
                if let Some(mut value) = read_plist_file(&path) {
                    let mut touched = false;
                    if let Some(dict) = value.as_dictionary_mut() {
                        if dict.get("wallpaperRepresentingIdentifier").is_some() {
                            dict.insert(
                                "wallpaperRepresentingIdentifier".into(),
                                plist::Value::Integer((new_id as i64).into()),
                            );
                            touched = true;
                        }
                    }
                    if touched && write_plist_file(&path, &value) {
                        rewritten = true;
                    }
                }
            }
            _ if name.ends_with("Wallpaper.plist") => {
                if let Some(mut value) = read_plist_file(&path) {
                    let mut touched = false;
                    if let Some(dict) = value.as_dictionary_mut() {
                        dict.insert(
                            "identifier".into(),
                            plist::Value::Integer((new_id as i64).into()),
                        );
                        touched = true;
                    }
                    if touched && write_plist_file(&path, &value) {
                        rewritten = true;
                    }
                }
            }
            _ => {}
        }
    }
    if rewritten {
        log.log(format!(
            "壁纸准备：标识符已改写为随机 5 位 ID {new_id}（三处）"
        ));
    } else {
        log.log("壁纸准备：标识符非纯数字或不可改写，保持原样".to_string());
    }
    rewritten
}

fn read_plist_file(path: &Path) -> Option<plist::Value> {
    let file = std::fs::File::open(path).ok()?;
    plist::Value::from_reader(std::io::BufReader::new(file)).ok()
}

fn write_plist_file(path: &Path, value: &plist::Value) -> bool {
    match std::fs::File::create(path) {
        Ok(mut file) => plist::to_writer_binary(&mut file, value).is_ok(),
        Err(_) => false,
    }
}

/// The PosterBoard refresh plist: asks PosterBoard to reset file
/// protections and re-read its galleries after an inject.
fn refresh_plist_bytes() -> Result<Vec<u8>, String> {
    let mut dict = plist::Dictionary::new();
    dict.insert(
        "PBF_RESET_FILE_PROTECTIONS".into(),
        plist::Value::Boolean(true),
    );
    dict.insert("PBF_LOCALE_DID_CHANGE".into(), plist::Value::Boolean(true));
    let persisted: Vec<plist::Value> = [
        "com.apple.Posters.CollectionsPosterApp",
        "com.apple.WallpaperKit.CollectionsPoster",
        "com.apple.MercuryPoster",
        "com.apple.Posters.MercuryPosterApp",
        "com.apple.PhotosUIPrivate.PhotosPosterProvider",
    ]
    .iter()
    .map(|s| plist::Value::String(s.to_string()))
    .collect();
    dict.insert(
        "PersistedPosterContainerBundleIdentifiers".into(),
        plist::Value::Array(persisted),
    );
    let migrations: Vec<plist::Value> = [
        "com.apple.Posters.UnityPosterApp.ExtragalacticPoster",
        "com.apple.Posters.WeatherPosterApp.WeatherPoster",
        "com.apple.Posters.UnityPosterApp.Unity2025Poster",
        "com.apple.Posters.UnityPosterApp.UnityPosterExtension",
        "com.apple.Posters.UnityPosterApp.RhizomePoster",
        "com.apple.Posters.KaleidoscopePosterApp.KaleidoscopePoster",
    ]
    .iter()
    .map(|s| plist::Value::String(s.to_string()))
    .collect();
    dict.insert(
        "CompletedPosterBundleIdentifierMigrations".into(),
        plist::Value::Array(migrations),
    );
    let mut buf = Vec::new();
    plist::to_writer_binary(&mut buf, &plist::Value::Dictionary(dict))
        .map_err(|e| format!("编码刷新 plist 失败: {e}"))?;
    Ok(buf)
}

pub struct ApplyReport {
    pub uuid: String,
    pub identifier_rewritten: bool,
    pub primary_before: usize,
    pub primary_after: usize,
    /// "ok" | "skipped" | "failed: <error>"
    pub dual: String,
    pub product_version: Option<String>,
}

/// Full wallpaper apply for one descriptor folder: locate the
/// PosterBoard container, prep a staging copy (new UUID + identifier
/// rewrite), inject into the CollectionsPoster store, dual-inject into
/// the modern Posters store on iOS 18+, then write the refresh plist
/// (container preferences, plus best-effort mobile preferences).
/// Respring stays a separate step (cw_device_respring).
pub async fn apply_wallpaper(
    pairing_path: &str,
    descriptor_dir: &Path,
    log: &Logger,
) -> Result<ApplyReport, String> {
    let mut tunnel = open_tunnel(pairing_path, log).await?;
    let product_version = tunnel.product_version(log).await;
    let major: Option<u64> = product_version
        .as_deref()
        .and_then(|v| v.split('.').next())
        .and_then(|m| m.parse().ok());

    let container = container_via(&mut tunnel, POSTERBOARD_BUNDLE_ID, log).await?;
    log.log(format!("壁纸应用：PosterBoard 容器 {container}"));

    // Prep a staging copy — the user's imported package is never mutated.
    let uuid = stage::new_uuid_upper();
    let prep_dir = std::env::temp_dir().join(format!(
        "cocowall-apply-{}",
        stage::random_hex(6)
    ));
    let prep_result = (|| -> Result<bool, String> {
        copy_dir_recursive(descriptor_dir, &prep_dir)?;
        Ok(rewrite_descriptor_identifiers(
            &prep_dir,
            stage::random_5_digit(),
            log,
        ))
    })();
    let identifier_rewritten = match prep_result {
        Ok(v) => v,
        Err(e) => {
            let _ = std::fs::remove_dir_all(&prep_dir);
            return Err(e);
        }
    };
    log.log(format!("壁纸应用：新 descriptor UUID {uuid}"));

    let store_base = format!(
        "{container}/Library/Application Support/PRBPosterExtensionDataStore/{STORE_VERSION}/Extensions"
    );
    let primary_parent = format!("{store_base}/{COLLECTIONS_EXT}/descriptors");
    let primary = inject_folder_via(&mut tunnel, &prep_dir, &primary_parent, &uuid, log).await;
    let primary = match primary {
        Ok(o) => o,
        Err(e) => {
            let _ = std::fs::remove_dir_all(&prep_dir);
            return Err(format!("主注入失败: {e}"));
        }
    };
    log.log(format!(
        "壁纸应用：主注入完成（gallery {} → {}）",
        primary.before_count, primary.after_count
    ));

    // iOS 18+ dual write into the modern extension store (best effort,
    // mirroring the reference flow's `try?`).
    let dual = if major.map(|m| m >= 18).unwrap_or(true) {
        let modern_parent = format!("{store_base}/{MODERN_COLLECTIONS_EXT}/descriptors");
        match inject_folder_via(&mut tunnel, &prep_dir, &modern_parent, &uuid, log).await {
            Ok(o) => {
                log.log(format!(
                    "壁纸应用：双写完成（gallery {} → {}）",
                    o.before_count, o.after_count
                ));
                "ok".to_string()
            }
            Err(e) => {
                log.log(format!("壁纸应用：双写失败（不影响主注入）: {e}"));
                format!("failed: {e}")
            }
        }
    } else {
        log.log("壁纸应用：iOS 18 以下，跳过双写".to_string());
        "skipped".to_string()
    };

    // Refresh plist into the container preferences (fatal on failure —
    // without it PosterBoard may never surface the new descriptor),
    // plus a best-effort copy into the global mobile preferences.
    let refresh = refresh_plist_bytes()?;
    let files = vec![(REFRESH_PLIST_NAME.to_string(), refresh)];
    write_files_via(
        &mut tunnel,
        &files,
        &format!("{container}/Library/Preferences"),
        log,
    )
    .await
    .map_err(|e| format!("写入刷新 plist（容器 Preferences）失败: {e}"))?;
    log.log("壁纸应用：刷新 plist 已写入容器 Preferences".to_string());
    match write_files_via(&mut tunnel, &files, "/var/mobile/Library/Preferences", log).await {
        Ok(_) => log.log("壁纸应用：刷新 plist 已写入全局 Preferences".to_string()),
        Err(e) => log.log(format!(
            "壁纸应用：全局 Preferences 写入失败（尽力而为，忽略）: {e}"
        )),
    }

    let _ = std::fs::remove_dir_all(&prep_dir);
    Ok(ApplyReport {
        uuid,
        identifier_rewritten,
        primary_before: primary.before_count,
        primary_after: primary.after_count,
        dual,
        product_version,
    })
}
