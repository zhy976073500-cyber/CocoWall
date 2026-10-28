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
/// LibraryID used by the reference ATH implementation.
const LIBRARY_ID: &str = "5AC547BA5322B210";
const SYNC_HOST_NAME: &str = "cocowall";

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
    dict.get("Command")
        .and_then(|c| c.as_string())
        .map(|s| s.to_string())
}

fn build_host_info(grappa_token: &Option<Vec<u8>>) -> plist::Dictionary {
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
        plist::Value::String(LIBRARY_ID.into()),
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
    /// when a Capabilities message carried one.
    pub async fn wait_sync_allowed(
        &mut self,
        log: &Logger,
    ) -> Result<Option<(u32, u32, u32)>, String> {
        let mut grappa_info = None;
        for _ in 0..12 {
            match tokio::time::timeout(Duration::from_millis(1500), read_msg(&mut self.stream))
                .await
            {
                Ok(Ok(dict)) => {
                    if let Some(name) = msg_name(&dict) {
                        log.log(format!("同步：收到守护进程消息 '{name}'"));
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
    pub async fn handshake(
        &mut self,
        grappa_info: Option<(u32, u32, u32)>,
        log: &Logger,
    ) -> Result<(), String> {
        let grappa_token = grappa::generate_grappa_token(grappa_info, log);
        let host_info = build_host_info(&grappa_token);

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
                                log.log(
                                    "同步：守护进程报 SyncFailed（非致命，继续等待）".to_string(),
                                );
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
}
