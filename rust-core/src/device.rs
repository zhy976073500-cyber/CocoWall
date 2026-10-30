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
    // Diagnostic: the raw container path exactly as InstallationProxy
    // reported it, and the normalized form every target path is
    // built from.
    let normalized = container.replace("/private/var/", "/var/");
    log.log(format!(
        "诊断：InstallationProxy 返回 {bundle_id} 容器原始路径：{container}"
    ));
    if normalized != container {
        log.log(format!(
            "诊断：{bundle_id} 容器归一化后路径：{normalized}"
        ));
    }
    Ok(normalized)
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
    /// Target entry count read through the symlink before the sync,
    /// when that readback was possible at all.
    pub before_count: Option<usize>,
    /// Same, after the sync.
    pub after_count: Option<usize>,
    /// None when the readback confirmed the expectation; otherwise
    /// why confirmation failed. Delivery and confirmation are
    /// separate outcomes: a delivered sync with an unreadable target
    /// is reported as delivered-but-unconfirmed, never as confirmed
    /// and never as a failed sync.
    pub unconfirmed_reason: Option<String>,
}

impl SyncOutcome {
    pub fn confirmed(&self) -> bool {
        self.unconfirmed_reason.is_none()
    }
}

/// Judge the post-sync readback: None for "confirmed", otherwise the
/// reason confirmation failed (unreadable target, expected name
/// missing, or the count did not move for a new entry).
fn judge_confirmation(
    before: &Option<Vec<String>>,
    after: &Result<Vec<String>, String>,
    expected_names: &[String],
) -> Option<String> {
    let after = match after {
        Ok(names) => names,
        Err(e) => {
            return Some(format!("同步后经 symlink 回读目标目录失败（{e}）"));
        }
    };
    for name in expected_names {
        if !after.iter().any(|n| n == name) {
            return Some(format!("同步后目标目录中没有出现 '{name}'"));
        }
        if let Some(before_names) = before {
            if !before_names.iter().any(|n| n == name) && after.len() <= before_names.len() {
                return Some(format!(
                    "'{name}' 为新条目但目录计数未增加（{} → {}）",
                    before_names.len(),
                    after.len()
                ));
            }
        }
    }
    None
}

/// Drive one staged sync to delivery: ATC handshake, then a
/// FileComplete for EVERY staged asset (link first, payloads right
/// after), then a short settle window. The sync counts as delivered
/// once all FileCompletes went out — the completion rule the
/// reference flow uses (AirCard's inject functions send the
/// FileCompletes, settle ~2s, and return success; they never read
/// the target back, and SyncFailed is logged as non-fatal noise
/// everywhere in their session handling).
///
/// The gallery count readback through the symlink is kept only as a
/// best-effort confirmation on top of delivery: the AFC service
/// refuses to traverse the staging symlink into the PosterBoard
/// container (status 10, PermDenied — observed on device in run
/// #40), so an unreadable target downgrades the outcome to
/// "delivered, unconfirmed" with the reason attached. It can no
/// longer block the payload FileCompletes or the steps after the
/// sync — run #40 stalled exactly there, with only the link asset
/// ever completed.
async fn run_staged_sync(
    tunnel: &mut DeviceTunnel,
    afc: &mut AfcClient,
    staged: &StagedSync,
    expected_names: &[String],
    log: &Logger,
) -> Result<SyncOutcome, String> {
    // Baseline for the count comparison, taken while the staged
    // symlink is already sitting in Media. Best effort only.
    let before = match stage::list_dir_names(afc, &staged.link_destination).await {
        Ok(names) => {
            log.log(format!("校验：同步前目标目录共 {} 项", names.len()));
            Some(names)
        }
        Err(e) => {
            log.log(format!(
                "校验：同步前经 symlink 回读目标目录失败（不阻塞同步）: {e}"
            ));
            None
        }
    };

    let mut atc = AtcSession::connect(tunnel, log).await?;
    let grappa_info = atc
        .wait_sync_allowed(log, "同步", &staged.identifiers)
        .await?;
    atc.handshake(grappa_info, log, &staged.identifiers).await?;

    // Every FileComplete, link first. The payload must never wait
    // behind a readback again.
    let total = staged.identifiers.len();
    for i in 0..total {
        atc.file_complete(&staged.identifiers[i], &staged.destinations[i], log)
            .await?;
        if i + 1 < total {
            tokio::time::sleep(std::time::Duration::from_millis(900)).await;
        }
    }
    // Reference closing semantics: once every FileComplete is sent
    // the sync counts as delivered; the short settle window only
    // observes late daemon messages, it cannot revoke delivery.
    atc.drain_after_file_complete(log, &staged.identifiers).await;
    log.log("同步：全部 FileComplete 已发送——同步已交付".to_string());

    // Diagnostic second look (read-only): a fresh ATC session purely
    // to record the daemon's opening announcements again — above all
    // whether its InstalledAssets now lists our staged assets as
    // installed. Nothing branches on this probe; delivery and
    // confirmation are already decided, and a probe failure is only
    // logged. The sync session is dropped first, like the reference
    // flow drops its connection after the settle window.
    drop(atc);
    match AtcSession::connect(tunnel, log).await {
        Ok(mut probe) => {
            match probe
                .wait_sync_allowed(log, "复查", &staged.identifiers)
                .await
            {
                Ok(_) => {
                    log.log("复查：第二次会话的守护进程公告已记录".to_string());
                    // The probe never sends a sync request of its own,
                    // so it stops at the announcement stage and has no
                    // manifest stage; say so plainly instead of leaving
                    // the absence of a probe-side manifest dump
                    // ambiguous. (Any AssetManifest the daemon did
                    // send during the announcements would have been
                    // dumped in full by wait_sync_allowed itself.)
                    log.log(
                        "复查：复查会话止步于守护进程公告阶段（未发送同步请求），没有清单阶段；AssetManifest 全文与成员判定见同步会话的清单转储"
                            .to_string(),
                    );
                }
                Err(e) => log.log(format!(
                    "复查：第二次会话读取守护进程公告失败（仅诊断，忽略）: {e}"
                )),
            }
        }
        Err(e) => log.log(format!(
            "复查：第二次 ATC 会话连接失败（仅诊断，忽略）: {e}"
        )),
    }

    // Best-effort confirmation readback; its result never fails the
    // sync, it only decides confirmed vs. unconfirmed.
    let after = stage::list_dir_names(afc, &staged.link_destination).await;
    if let Ok(names) = &after {
        log.log(format!("校验：同步后目标目录共 {} 项", names.len()));
    }
    let unconfirmed_reason = judge_confirmation(&before, &after, expected_names);
    match &unconfirmed_reason {
        None => log.log("校验：计数已确认（目标目录含本次条目）".to_string()),
        Some(reason) => log.log(format!(
            "校验：计数未确认：{reason}——同步已交付，最终确认请在重启后看锁屏图库"
        )),
    }
    Ok(SyncOutcome {
        before_count: before.as_ref().map(|n| n.len()),
        after_count: after.as_ref().ok().map(|n| n.len()),
        unconfirmed_reason,
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
    let has_suggestion_metadata = dir
        .join("com.apple.posterkit.provider.identifierURL.suggestionMetadata.plist")
        .exists();
    log.log(format!(
        "诊断：suggestionMetadata 存在：{}",
        if has_suggestion_metadata { "是" } else { "否" }
    ));
    if has_suggestion_metadata {
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
                match std::fs::read_to_string(&path) {
                    Ok(content) => {
                        let old = content.trim().to_string();
                        if old.parse::<i64>().is_ok() {
                            match std::fs::write(&path, new_id.to_string()) {
                                Ok(()) => {
                                    rewritten = true;
                                    log.log(format!(
                                        "诊断：改写命中 descriptor.identifier：'{old}' → '{new_id}'"
                                    ));
                                }
                                Err(e) => log.log(format!(
                                    "诊断：改写 descriptor.identifier 失败（旧值 '{old}'）：{e}"
                                )),
                            }
                        } else {
                            log.log(format!(
                                "诊断：descriptor.identifier 内容 '{old}' 非纯数字，不改写"
                            ));
                        }
                    }
                    Err(e) => log.log(format!(
                        "诊断：读取 descriptor.identifier 失败：{e}"
                    )),
                }
            }
            "com.apple.posterkit.provider.contents.userInfo" => {
                if let Some(mut value) = read_plist_file(&path) {
                    let mut touched = false;
                    if let Some(dict) = value.as_dictionary_mut() {
                        match dict.get("wallpaperRepresentingIdentifier").cloned() {
                            Some(old) => {
                                log.log(format!(
                                    "诊断：改写命中 contents.userInfo 的 wallpaperRepresentingIdentifier：{old:?} → {new_id}"
                                ));
                                dict.insert(
                                    "wallpaperRepresentingIdentifier".into(),
                                    plist::Value::Integer((new_id as i64).into()),
                                );
                                touched = true;
                            }
                            None => log.log(
                                "诊断：contents.userInfo 无 wallpaperRepresentingIdentifier 键，不改写"
                                    .to_string(),
                            ),
                        }
                    }
                    if touched && write_plist_file(&path, &value) {
                        rewritten = true;
                    }
                } else {
                    log.log("诊断：contents.userInfo 不可解析，不改写".to_string());
                }
            }
            _ if name.ends_with("Wallpaper.plist") => {
                if let Some(mut value) = read_plist_file(&path) {
                    let mut touched = false;
                    if let Some(dict) = value.as_dictionary_mut() {
                        let old = dict.get("identifier").cloned();
                        log.log(format!(
                            "诊断：改写命中 {name} 的 identifier：{old:?} → {new_id}"
                        ));
                        dict.insert(
                            "identifier".into(),
                            plist::Value::Integer((new_id as i64).into()),
                        );
                        touched = true;
                    }
                    if touched && write_plist_file(&path, &value) {
                        rewritten = true;
                    }
                } else {
                    log.log(format!("诊断：{name} 不可解析，不改写"));
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

/// Every string value inside a plist value, recursively (device-side
/// twin of the helper in atc.rs, for the descriptor dumps below).
fn collect_value_strings(value: &plist::Value, out: &mut Vec<String>) {
    match value {
        plist::Value::String(s) => out.push(s.clone()),
        plist::Value::Array(items) => {
            for item in items {
                collect_value_strings(item, out);
            }
        }
        plist::Value::Dictionary(dict) => {
            for (_, v) in dict.iter() {
                collect_value_strings(v, out);
            }
        }
        _ => {}
    }
}

/// Diagnostic dump of the descriptor's providerInfo.plist: the
/// keyed-archiver header and every entry of its object table, so the
/// provider identity and version fields can be compared against what
/// the current iOS expects. Read-only; nothing branches on it.
fn log_provider_info(descriptor_dir: &Path, log: &Logger) {
    let path = descriptor_dir.join("providerInfo.plist");
    match read_plist_file(&path) {
        None => log.log("诊断：providerInfo.plist 不存在或不可解析".to_string()),
        Some(value) => {
            let Some(root) = value.as_dictionary() else {
                log.log("诊断：providerInfo.plist 顶层不是字典".to_string());
                return;
            };
            log.log(format!(
                "诊断：providerInfo：$archiver={:?}，$version={:?}",
                root.get("$archiver"),
                root.get("$version")
            ));
            match root.get("$objects").and_then(|v| v.as_array()) {
                Some(objects) => {
                    log.log(format!(
                        "诊断：providerInfo $objects 共 {} 项",
                        objects.len()
                    ));
                    for (i, obj) in objects.iter().enumerate() {
                        match obj {
                            plist::Value::String(s) => log.log(format!(
                                "诊断：providerInfo $objects[{i}] 字符串：'{s}'"
                            )),
                            plist::Value::Dictionary(d) => {
                                let mut keys: Vec<&str> =
                                    d.iter().map(|(k, _)| k.as_str()).collect();
                                keys.sort_unstable();
                                let mut line = format!(
                                    "诊断：providerInfo $objects[{i}] 字典键：{}",
                                    keys.join(", ")
                                );
                                if let Some(cn) =
                                    d.get("$classname").and_then(|v| v.as_string())
                                {
                                    line.push_str(&format!("（类 {cn}）"));
                                }
                                log.log(line);
                            }
                            plist::Value::Data(data) => log.log(format!(
                                "诊断：providerInfo $objects[{i}] 数据 {} 字节",
                                data.len()
                            )),
                            other => log.log(format!(
                                "诊断：providerInfo $objects[{i}]：{other:?}"
                            )),
                        }
                    }
                }
                None => {
                    let mut keys: Vec<&str> =
                        root.iter().map(|(k, _)| k.as_str()).collect();
                    keys.sort_unstable();
                    log.log(format!(
                        "诊断：providerInfo 无 $objects（非 NSKeyedArchiver 结构），顶层键：{}",
                        keys.join(", ")
                    ));
                }
            }
        }
    }
    // The descriptor's version directories are part of its version
    // story; list them alongside the provider dump.
    match std::fs::read_dir(descriptor_dir.join("versions")) {
        Ok(rd) => {
            let mut names: Vec<String> = rd
                .flatten()
                .map(|e| e.file_name().to_string_lossy().to_string())
                .collect();
            names.sort();
            log.log(format!(
                "诊断：descriptor versions 子目录：{}",
                names.join(", ")
            ));
        }
        Err(e) => log.log(format!("诊断：descriptor versions 子目录不可读：{e}")),
    }
}

/// Log-only mirror of the reference implementation's per-descriptor
/// extension resolution (AirCard's determineExtension, minus the
/// path-component and path-hint rules, which cannot apply to a
/// freshly extracted package): suggestionMetadata object strings
/// first, then the descriptor identifier's shape. Our inject path
/// keeps its fixed primary extension — this only records what the
/// reference rules would have chosen for this descriptor.
fn log_reference_extension(descriptor_dir: &Path, log: &Logger) {
    let mut resolved: Option<String> = None;
    let meta_path = descriptor_dir
        .join("com.apple.posterkit.provider.identifierURL.suggestionMetadata.plist");
    if let Some(value) = read_plist_file(&meta_path) {
        let mut strings = Vec::new();
        collect_value_strings(&value, &mut strings);
        log.log(format!(
            "诊断：suggestionMetadata 中的字符串：{}",
            strings.join(" | ")
        ));
        if let Some(s) = strings
            .iter()
            .find(|s| s.starts_with("com.apple.") && s.contains("Poster"))
        {
            resolved = Some(s.clone());
        }
    }
    let id_text = std::fs::read_to_string(
        descriptor_dir.join("com.apple.posterkit.provider.descriptor.identifier"),
    )
    .map(|s| s.trim().to_string())
    .unwrap_or_else(|_| "<不可读>".to_string());
    if resolved.is_none()
        && (id_text.starts_with("v6")
            || id_text.starts_with("v5")
            || id_text.starts_with("v4")
            || id_text.contains(".color"))
    {
        resolved = Some("com.apple.MercuryPoster".to_string());
    }
    let resolved = resolved.unwrap_or_else(|| COLLECTIONS_EXT.to_string());
    log.log(format!(
        "诊断：按参考实现规则本包 ext 解析为 {resolved}（descriptor.identifier 内容 '{id_text}'，无任何特征命中时默认 {COLLECTIONS_EXT}）；本应用主注入写死为 {COLLECTIONS_EXT}"
    ));
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
    pub primary_before: Option<usize>,
    pub primary_after: Option<usize>,
    /// None = the post-sync readback confirmed the new descriptor;
    /// Some(reason) = the sync was delivered but the count could not
    /// be confirmed (the usual case on device: AFC refuses the
    /// readback through the symlink).
    pub primary_unconfirmed: Option<String>,
    /// "ok" | "skipped" | "failed: <error>"
    pub dual: String,
    pub product_version: Option<String>,
}

/// One log line describing a finished sync: delivered, and whether
/// the gallery count was confirmed.
fn describe_outcome(label: &str, outcome: &SyncOutcome) -> String {
    match (&outcome.unconfirmed_reason, outcome.before_count, outcome.after_count) {
        (None, Some(b), Some(a)) => format!("{label}完成，计数已确认（gallery {b} → {a}）"),
        (None, _, Some(a)) => {
            format!("{label}完成，计数已确认（目标目录共 {a} 项，含本次条目）")
        }
        (None, _, None) => format!("{label}完成，计数已确认"),
        (Some(reason), _, _) => format!("{label}同步已交付，计数未确认（{reason}）"),
    }
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
    // Session topology mirrors the reference flow: the version and
    // container lookup below uses a short-lived tunnel of its own, and
    // every write operation further down (primary inject, dual inject,
    // each refresh write) establishes a fresh tunnel connection that
    // is dropped when the operation ends — the reference reconnects
    // for every operation instead of sharing one tunnel across the
    // whole apply. Only the connection lifecycle changes here;
    // staging, ATC message content and order, Books snapshot/restore
    // (already inside each operation) and the delivery criteria are
    // untouched.
    let (product_version, major, container) = {
        let mut tunnel = open_tunnel(pairing_path, log).await?;
        let product_version = tunnel.product_version(log).await;
        let major: Option<u64> = product_version
            .as_deref()
            .and_then(|v| v.split('.').next())
            .and_then(|m| m.parse().ok());

        log.log(format!(
            "诊断：设备系统版本 {}（大版本 {}），STORE_VERSION={STORE_VERSION}",
            product_version.as_deref().unwrap_or("<未知>"),
            major
                .map(|m| m.to_string())
                .unwrap_or_else(|| "<未知>".to_string())
        ));

        let container = container_via(&mut tunnel, POSTERBOARD_BUNDLE_ID, log).await?;
        log.log(format!("壁纸应用：PosterBoard 容器 {container}"));
        (product_version, major, container)
    };

    // Descriptor-side diagnostic dumps, all read-only: the original
    // UUID (the descriptor folder's name), providerInfo.plist's key
    // fields, and the extension the reference rules would resolve.
    let original_uuid = descriptor_dir
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    log.log(format!(
        "诊断：原 descriptor 文件夹名（原 UUID）：{original_uuid}"
    ));
    log_provider_info(descriptor_dir, log);
    log_reference_extension(descriptor_dir, log);

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
    log.log(format!(
        "诊断：主注入 descriptor 最终目标路径：{primary_parent}/{uuid}（ext={COLLECTIONS_EXT}）"
    ));
    // The public inject_folder entry opens a fresh tunnel for this
    // operation alone and drops it on return (per-operation reconnect).
    let primary = inject_folder(pairing_path, &prep_dir, &primary_parent, &uuid, log).await;
    let primary = match primary {
        Ok(o) => o,
        Err(e) => {
            let _ = std::fs::remove_dir_all(&prep_dir);
            return Err(format!("主注入失败: {e}"));
        }
    };
    log.log(format!(
        "壁纸应用：{}",
        describe_outcome("主注入", &primary)
    ));

    // iOS 18+ dual write into the modern extension store (best effort,
    // mirroring the reference flow's `try?`). Every step of the dual
    // branch is logged explicitly — decision, target, result — so a
    // device log shows whether it ran and where it wrote.
    log.log(format!(
        "诊断：双写判定输入：iOS 大版本 {}，主 ext={COLLECTIONS_EXT}，候选双写 ext={MODERN_COLLECTIONS_EXT}",
        major
            .map(|m| m.to_string())
            .unwrap_or_else(|| "<未知>".to_string())
    ));
    let dual = if major.map(|m| m >= 18).unwrap_or(true) {
        let modern_parent = format!("{store_base}/{MODERN_COLLECTIONS_EXT}/descriptors");
        log.log(format!(
            "诊断：双写执行，descriptor 最终目标路径：{modern_parent}/{uuid}"
        ));
        match inject_folder(pairing_path, &prep_dir, &modern_parent, &uuid, log).await {
            Ok(o) => {
                log.log(format!(
                    "壁纸应用：{}",
                    describe_outcome("双写", &o)
                ));
                log.log("诊断：双写结果：ok".to_string());
                "ok".to_string()
            }
            Err(e) => {
                log.log(format!("壁纸应用：双写失败（不影响主注入）: {e}"));
                log.log(format!("诊断：双写结果：failed: {e}"));
                format!("failed: {e}")
            }
        }
    } else {
        log.log("壁纸应用：iOS 18 以下，跳过双写".to_string());
        log.log("诊断：双写结果：skipped（iOS 大版本 < 18）".to_string());
        "skipped".to_string()
    };

    // Refresh plist into the container preferences (fatal on failure —
    // without it PosterBoard may never surface the new descriptor),
    // plus a best-effort copy into the global mobile preferences.
    // Both targets and both results are logged explicitly.
    let refresh = refresh_plist_bytes()?;
    let files = vec![(REFRESH_PLIST_NAME.to_string(), refresh)];
    let refresh_target_1 = format!("{container}/Library/Preferences");
    let refresh_target_2 = "/var/mobile/Library/Preferences".to_string();
    log.log(format!(
        "诊断：刷新偏好目标 1（容器）：{refresh_target_1}/{REFRESH_PLIST_NAME}"
    ));
    // Fresh tunnel for this refresh write, dropped when it ends.
    let refresh_1 = match open_tunnel(pairing_path, log).await {
        Ok(mut tunnel) => write_files_via(&mut tunnel, &files, &refresh_target_1, log).await,
        Err(e) => Err(e),
    };
    refresh_1.map_err(|e| format!("写入刷新 plist（容器 Preferences）失败: {e}"))?;
    log.log(format!(
        "诊断：刷新偏好目标 1 写入结果：成功（{refresh_target_1}/{REFRESH_PLIST_NAME}）"
    ));
    log.log(format!(
        "诊断：刷新偏好目标 2（全局）：{refresh_target_2}/{REFRESH_PLIST_NAME}"
    ));
    // Fresh tunnel for this refresh write too, dropped when it ends.
    let refresh_2 = match open_tunnel(pairing_path, log).await {
        Ok(mut tunnel) => write_files_via(&mut tunnel, &files, &refresh_target_2, log).await,
        Err(e) => Err(e),
    };
    match refresh_2 {
        Ok(_) => log.log(format!(
            "诊断：刷新偏好目标 2 写入结果：成功（{refresh_target_2}/{REFRESH_PLIST_NAME}）"
        )),
        Err(e) => log.log(format!(
            "诊断：刷新偏好目标 2 写入结果：失败（尽力而为，忽略）：{e}"
        )),
    }

    let _ = std::fs::remove_dir_all(&prep_dir);
    Ok(ApplyReport {
        uuid,
        identifier_rewritten,
        primary_before: primary.before_count,
        primary_after: primary.after_count,
        primary_unconfirmed: primary.unconfirmed_reason,
        dual,
        product_version,
    })
}
