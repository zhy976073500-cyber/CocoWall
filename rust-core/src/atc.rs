//! The com.apple.atc (AirTraffic) Book-class sync session.
//!
//! Wire format: a 4-byte length prefix (little-endian when sending;
//! both endians accepted when reading) followed by a binary-plist
//! dictionary `{Command, Session, Params}`. The daemon announces
//! `Capabilities` (carrying GrappaSupportInfo) and `SyncAllowed`; the
//! host answers with `HostInfo` (session 0) and `RequestingSync`
//! (session 1) for the Book dataclass, waits for `ReadyForSync`
//! (answering `Ping` with `Pong`, tolerating `SyncFailed` as a notice),
//! sends `FinishedSyncingMetadata`, waits for `AssetManifest`, and then
//! issues one `FileComplete` per staged asset. Protocol facts as
//! recorded in research/airlift-implementation-notes.md.

use std::time::Duration;

use idevice::ReadWrite;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::device_log::Logger;
use crate::grappa;
use crate::tunnel::DeviceTunnel;

const ATC_SERVICE: &str = "com.apple.atc";
const SYNC_HOST_NAME: &str = "cocowall";

/// LibraryID for one sync session, shaped like a UUID
/// (8-4-4-4-12 hex). The reference implementation that runs this
/// handshake on iOS generates a fresh one per session; the fixed ID
/// this code used before came from a desktop ATH implementation and
/// named a library this device has never seen. Not security material —
/// just an identifier — so time/counter entropy is enough.
fn random_library_id() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    let count = COUNTER.fetch_add(1, Ordering::Relaxed);
    let mut x = nanos
        ^ count.wrapping_mul(0x9E37_79B9_7F4A_7C15)
        ^ ((std::process::id() as u64) << 17);
    let mut next = move || {
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    };
    let a = next() as u32;
    let b = (next() >> 16) as u16;
    let c = next() as u16;
    let d = (next() >> 32) as u16;
    let e = next() & 0xFFFF_FFFF_FFFF;
    format!("{a:08x}-{b:04x}-{c:04x}-{d:04x}-{e:012x}")
}

fn make_msg(command: &str, session: u64, params: Option<plist::Dictionary>) -> plist::Value {
    let mut dict = plist::Dictionary::new();
    dict.insert(
        "Command".into(),
        plist::Value::String(command.to_string()),
    );
    dict.insert("Session".into(), plist::Value::Integer(session.into()));
    if let Some(p) = params {
        dict.insert("Params".into(), plist::Value::Dictionary(p));
    }
    plist::Value::Dictionary(dict)
}

async fn send_msg(stream: &mut Box<dyn ReadWrite>, msg: &plist::Value) -> Result<(), String> {
    let mut buf = Vec::new();
    plist::to_writer_binary(&mut buf, msg)
        .map_err(|e| format!("同步：编码 ATC 消息失败: {e}"))?;
    let len = (buf.len() as u32).to_le_bytes();
    stream
        .write_all(&len)
        .await
        .map_err(|e| format!("同步：发送 ATC 长度前缀失败: {e}"))?;
    stream
        .write_all(&buf)
        .await
        .map_err(|e| format!("同步：发送 ATC 消息失败: {e}"))?;
    stream
        .flush()
        .await
        .map_err(|e| format!("同步：flush ATC 流失败: {e}"))?;
    Ok(())
}

async fn read_msg(stream: &mut Box<dyn ReadWrite>) -> Result<plist::Dictionary, String> {
    let mut len_buf = [0u8; 4];
    stream
        .read_exact(&mut len_buf)
        .await
        .map_err(|e| format!("同步：读取 ATC 长度前缀失败: {e}"))?;
    let le = u32::from_le_bytes(len_buf) as usize;
    let be = u32::from_be_bytes(len_buf) as usize;
    let len = if (1..=1_000_000).contains(&le) {
        le
    } else if (1..=1_000_000).contains(&be) {
        be
    } else {
        return Err(format!(
            "同步：ATC 长度前缀异常（LE={le}, BE={be}）"
        ));
    };
    let mut body = vec![0u8; len];
    stream
        .read_exact(&mut body)
        .await
        .map_err(|e| format!("同步：读取 ATC 消息体失败: {e}"))?;
    let value: plist::Value = plist::from_reader(std::io::Cursor::new(body))
        .map_err(|e| format!("同步：解码 ATC plist 失败: {e}"))?;
    value
        .as_dictionary()
        .cloned()
        .ok_or_else(|| "同步：ATC 消息不是字典".to_string())
}

fn msg_name(dict: &plist::Dictionary) -> Option<String> {
    /* The daemon normally uses "Command"; some builds name the same
     * field "MessageName" — accept both, like the reference reader. */
    dict.get("Command")
        .or_else(|| dict.get("MessageName"))
        .and_then(|c| c.as_string())
        .map(|s| s.to_string())
}

/// Every string value inside a plist value, recursively — used to
/// search a daemon message for our staged asset identifiers without
/// assuming the message's exact schema.
fn collect_strings(value: &plist::Value, out: &mut Vec<String>) {
    match value {
        plist::Value::String(s) => out.push(s.clone()),
        plist::Value::Array(items) => {
            for item in items {
                collect_strings(item, out);
            }
        }
        plist::Value::Dictionary(dict) => {
            for (_, v) in dict.iter() {
                collect_strings(v, out);
            }
        }
        _ => {}
    }
}

/// Diagnostic dump of one InstalledAssets message: the full message,
/// every string in its Params, and whether each watched identifier
/// (our staged Book assets) appears among them. Read-only — callers
/// keep their existing handling of the message; nothing in the sync
/// flow branches on what is logged here.
fn log_installed_assets(
    dict: &plist::Dictionary,
    watch_ids: &[String],
    log: &Logger,
    label: &str,
) {
    log.log(format!("{label}：InstalledAssets 完整内容：{dict:?}"));
    let mut strings = Vec::new();
    if let Some(params) = dict.get("Params") {
        collect_strings(params, &mut strings);
    }
    log.log(format!(
        "{label}：InstalledAssets 中共 {} 个字符串：{}",
        strings.len(),
        strings.join(" | ")
    ));
    for id in watch_ids {
        let present = strings.iter().any(|s| s == id);
        log.log(format!(
            "{label}：暂存资产 '{id}' 在 InstalledAssets 中：{}",
            if present { "在" } else { "不在" }
        ));
    }
}

fn build_host_info(grappa_token: &Option<Vec<u8>>, library_id: &str) -> plist::Dictionary {
    let mut host = plist::Dictionary::new();
    host.insert("Type".into(), plist::Value::String("iTunes".into()));
    host.insert(
        "Version".into(),
        plist::Value::String("13.7.0.161".into()),
    );
    host.insert(
        "MacOSVersion".into(),
        plist::Value::String("15.0".into()),
    );
    host.insert(
        "SyncHostName".into(),
        plist::Value::String(SYNC_HOST_NAME.into()),
    );
    host.insert(
        "LibraryID".into(),
        plist::Value::String(library_id.into()),
    );
    host.insert(
        "SyncedDataclasses".into(),
        plist::Value::Array(vec![plist::Value::String("Book".into())]),
    );
    host.insert(
        "SyncedAssetTypes".into(),
        plist::Value::Array(vec![plist::Value::String("Book".into())]),
    );
    host.insert("Wakeable".into(), plist::Value::Boolean(false));
    if let Some(token) = grappa_token {
        host.insert("Grappa".into(), plist::Value::Data(token.clone()));
    }
    host
}

/// One AirTraffic session over an already-connected tunnel.
pub struct AtcSession {
    stream: Box<dyn ReadWrite>,
}

impl AtcSession {
    pub async fn connect(tunnel: &mut DeviceTunnel, log: &Logger) -> Result<Self, String> {
        let stream = tunnel.connect_raw_service(ATC_SERVICE, log).await?;
        log.log("同步：com.apple.atc 已连接".to_string());
        Ok(Self { stream })
    }

    /// Wait for the daemon's opening messages; returns the
    /// GrappaSupportInfo triple (version, deviceType, protocolVersion)
    /// when a Capabilities message carried one. `label` prefixes the
    /// log lines so a diagnostic second session ("复查") reads
    /// differently from the sync session itself ("同步");
    /// `watch_ids` are the staged asset identifiers checked against
    /// any InstalledAssets announcement.
    pub async fn wait_sync_allowed(
        &mut self,
        log: &Logger,
        label: &str,
        watch_ids: &[String],
    ) -> Result<Option<(u32, u32, u32)>, String> {
        let mut grappa_info = None;
        for _ in 0..12 {
            match tokio::time::timeout(Duration::from_millis(1500), read_msg(&mut self.stream))
                .await
            {
                Ok(Ok(dict)) => {
                    if let Some(name) = msg_name(&dict) {
                        log.log(format!("{label}：收到守护进程消息 '{name}'"));
                        if name == "InstalledAssets" {
                            log_installed_assets(&dict, watch_ids, log, label);
                        }
                        if name == "Capabilities" {
                            if let Some(gi) = dict
                                .get("Params")
                                .and_then(|p| p.as_dictionary())
                                .and_then(|p| p.get("GrappaSupportInfo"))
                                .and_then(|g| g.as_dictionary())
                            {
                                let ver = gi
                                    .get("version")
                                    .and_then(|v| v.as_unsigned_integer())
                                    .unwrap_or(1) as u32;
                                let dt = gi
                                    .get("deviceType")
                                    .and_then(|v| v.as_unsigned_integer())
                                    .unwrap_or(0) as u32;
                                let pv = gi
                                    .get("protocolVersion")
                                    .and_then(|v| v.as_unsigned_integer())
                                    .unwrap_or(1) as u32;
                                grappa_info = Some((ver, dt, pv));
                                log.log(format!(
                                    "{label}：守护进程 GrappaSupportInfo：version={ver} deviceType={dt} protocolVersion={pv}"
                                ));
                            }
                        }
                        if name == "SyncAllowed" {
                            break;
                        }
                    }
                }
                Ok(Err(e)) => return Err(e),
                Err(_) => break, // daemon went quiet; proceed like the reference flow
            }
        }
        Ok(grappa_info)
    }

    /// HostInfo → RequestingSync → ReadyForSync → FinishedSyncingMetadata
    /// → AssetManifest. After this returns, FileComplete messages can go.
    /// `watch_ids` only feeds the InstalledAssets diagnostic dump.
    pub async fn handshake(
        &mut self,
        grappa_info: Option<(u32, u32, u32)>,
        log: &Logger,
        watch_ids: &[String],
    ) -> Result<(), String> {
        let grappa_token = grappa::generate_grappa_token(grappa_info, log);
        match &grappa_token {
            Some(token) => log.log(format!(
                "同步：Grappa token 将写入 HostInfo 字典的 'Grappa' 键与 RequestingSync 参数的 'Grappa' 键（{} 字节）",
                token.len()
            )),
            None => log.log(
                "同步：无 Grappa token——HostInfo 与 RequestingSync 均不带 'Grappa' 键，守护进程可能因此拒绝进入 ReadyForSync"
                    .to_string(),
            ),
        }
        let library_id = random_library_id();
        log.log(format!(
            "同步：本次会话 LibraryID（每会话随机生成）: {library_id}"
        ));
        let host_info = build_host_info(&grappa_token, &library_id);

        // HostInfo, session 0.
        let mut params = plist::Dictionary::new();
        params.insert(
            "HostInfo".into(),
            plist::Value::Dictionary(host_info.clone()),
        );
        params.insert("LocalCloudSupport".into(), plist::Value::Boolean(false));
        send_msg(&mut self.stream, &make_msg("HostInfo", 0, Some(params))).await?;
        log.log("同步：HostInfo 已发送".to_string());
        tokio::time::sleep(Duration::from_millis(200)).await;

        // RequestingSync for the Book dataclass, session 1.
        let mut params = plist::Dictionary::new();
        params.insert(
            "Dataclasses".into(),
            plist::Value::Array(vec![plist::Value::String("Book".into())]),
        );
        params.insert(
            "DataclassAnchors".into(),
            plist::Value::Dictionary(plist::Dictionary::new()),
        );
        params.insert(
            "HostInfo".into(),
            plist::Value::Dictionary(host_info),
        );
        if let Some(token) = grappa_token {
            params.insert("Grappa".into(), plist::Value::Data(token));
        }
        send_msg(
            &mut self.stream,
            &make_msg("RequestingSync", 1, Some(params)),
        )
        .await?;
        log.log("同步：RequestingSync（Book）已发送".to_string());

        // Wait for ReadyForSync.
        let mut ready = false;
        for _ in 0..24 {
            match tokio::time::timeout(Duration::from_secs(5), read_msg(&mut self.stream)).await {
                Ok(Ok(dict)) => {
                    if let Some(name) = msg_name(&dict) {
                        log.log(format!("同步：守护进程状态 '{name}'"));
                        match name.as_str() {
                            "Ping" => {
                                let pong = make_msg("Pong", 1, None);
                                let _ = send_msg(&mut self.stream, &pong).await;
                            }
                            "ReadyForSync" | "AssetManifest" => {
                                ready = true;
                                break;
                            }
                            "SyncFailed" => {
                                /* Dump the full message: its ErrorCode
                                 * distinguishes a stale prior-session
                                 * cancellation (routine) from an auth
                                 * rejection (the thing we are hunting). */
                                log.log(format!(
                                    "同步：守护进程报 SyncFailed（继续等待）：{dict:?}"
                                ));
                            }
                            "InstalledAssets" => {
                                log_installed_assets(&dict, watch_ids, log, "同步");
                            }
                            _ => {}
                        }
                    }
                }
                Ok(Err(e)) => return Err(e),
                Err(_) => {}
            }
        }
        if !ready {
            return Err(
                "同步：等待 ReadyForSync 超时（请确认设备上已安装 Apple Books）".to_string(),
            );
        }

        // FinishedSyncingMetadata, then wait for the AssetManifest.
        let mut sync_types = plist::Dictionary::new();
        sync_types.insert("Book".into(), plist::Value::Integer(1.into()));
        let mut params = plist::Dictionary::new();
        params.insert("SyncTypes".into(), plist::Value::Dictionary(sync_types));
        params.insert(
            "DataclassAnchors".into(),
            plist::Value::Dictionary(plist::Dictionary::new()),
        );
        send_msg(
            &mut self.stream,
            &make_msg("FinishedSyncingMetadata", 1, Some(params)),
        )
        .await?;
        log.log("同步：FinishedSyncingMetadata 已发送".to_string());

        let mut manifest = false;
        for _ in 0..30 {
            match tokio::time::timeout(Duration::from_secs(2), read_msg(&mut self.stream)).await {
                Ok(Ok(dict)) => {
                    if let Some(name) = msg_name(&dict) {
                        log.log(format!("同步：守护进程状态 '{name}'"));
                        match name.as_str() {
                            "Ping" => {
                                let pong = make_msg("Pong", 1, None);
                                let _ = send_msg(&mut self.stream, &pong).await;
                            }
                            "AssetManifest" | "SyncFinished" => {
                                manifest = true;
                                break;
                            }
                            "SyncFailed" => {
                                log.log(format!(
                                    "同步：守护进程报 SyncFailed（清单阶段，继续等待）：{dict:?}"
                                ));
                            }
                            "InstalledAssets" => {
                                log_installed_assets(&dict, watch_ids, log, "同步");
                            }
                            _ => {}
                        }
                    }
                }
                Ok(Err(e)) => return Err(e),
                Err(_) => break,
            }
        }
        if manifest {
            log.log("同步：AssetManifest 已到，可以发送 FileComplete".to_string());
        } else {
            log.log("同步：未等到 AssetManifest，按参考流程继续发送 FileComplete".to_string());
        }
        Ok(())
    }

    /// Tell the daemon one staged asset has landed at its destination.
    pub async fn file_complete(
        &mut self,
        asset_id: &str,
        destination: &str,
        log: &Logger,
    ) -> Result<(), String> {
        let mut params = plist::Dictionary::new();
        params.insert(
            "AssetID".into(),
            plist::Value::String(asset_id.to_string()),
        );
        params.insert(
            "Dataclass".into(),
            plist::Value::String("Book".into()),
        );
        params.insert(
            "AssetPath".into(),
            plist::Value::String(destination.to_string()),
        );
        send_msg(
            &mut self.stream,
            &make_msg("FileComplete", 1, Some(params)),
        )
        .await?;
        log.log(format!("同步：FileComplete 已发送 → {destination}"));
        Ok(())
    }

    /// Settle briefly after the last FileComplete, mirroring the
    /// reference flow: it waits ~2s and drops the connection without
    /// awaiting any daemon confirmation. Messages in the window are
    /// only observed — Pings are answered with Pong, and a SyncFailed
    /// here is logged as a notice, not a verdict: the reference treats
    /// SyncFailed as non-fatal throughout the session (it commonly
    /// reports a stale prior-session cancellation), and delivery is
    /// already decided by the completed FileComplete sequence.
    pub async fn drain_after_file_complete(&mut self, log: &Logger, watch_ids: &[String]) {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        loop {
            let now = tokio::time::Instant::now();
            if now >= deadline {
                return;
            }
            match tokio::time::timeout(deadline - now, read_msg(&mut self.stream)).await {
                Ok(Ok(dict)) => {
                    if let Some(name) = msg_name(&dict) {
                        log.log(format!("同步：FileComplete 后守护进程状态 '{name}'"));
                        match name.as_str() {
                            "Ping" => {
                                let pong = make_msg("Pong", 1, None);
                                let _ = send_msg(&mut self.stream, &pong).await;
                            }
                            "SyncFailed" => {
                                log.log(format!(
                                    "同步：FileComplete 后守护进程报 SyncFailed（按参考流程仅记录，不改变交付结论）：{dict:?}"
                                ));
                            }
                            "InstalledAssets" => {
                                log_installed_assets(&dict, watch_ids, log, "同步");
                            }
                            _ => {}
                        }
                    }
                }
                Ok(Err(_)) => return,
                Err(_) => return,
            }
        }
    }
}
