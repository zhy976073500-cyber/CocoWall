//! Device connection: reach the phone through our own loopback packet
//! tunnel and hand back either an RSD session or a lockdown session.
//!
//! Route order (each attempt is logged, failures fall through):
//!   1. RSD over a RemotePairing TLS-PSK tunnel — connect to the device's
//!      remotepairing front door on :49152, verify the stored pairing,
//!      open the CDTunnel, run the RSD handshake inside it. This is the
//!      modern iOS 17+ route and the only one that exposes the `.shim`
//!      services the writer needs.
//!   2. Lockdown over plain TCP :62078 with the pairing record's TLS
//!      session — the classic fallback.
//!
//! The target host defaults to 10.7.0.1, the address our packet tunnel
//! swaps toward the device (see PacketTunnelProvider); Swift may override
//! it through `cw_set_target_host`.

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Mutex;
use std::time::Duration;

use idevice::pairing_file::PairingFile;
use idevice::provider::{IdeviceProvider, TcpProvider};
use idevice::remote_pairing::{connect_tls_psk_tunnel_native, RemotePairingClient, RpPairingFile, RpPairingSocket};
use idevice::services::lockdown::LockdownClient;
use idevice::tcp::adapter::Adapter;
use idevice::tcp::handle::AdapterHandle;
use idevice::{Idevice, IdeviceService, ReadWrite};
use tokio::net::TcpStream;

use crate::device_log::Logger;

pub const RSD_PORT: u16 = 49152;
pub const LOCKDOWN_PORT: u16 = 62078;

static TARGET_HOST: Mutex<Option<String>> = Mutex::new(None);

pub fn set_target_host(host: Option<String>) {
    if let Ok(mut g) = TARGET_HOST.lock() {
        *g = host;
    }
}

pub fn target_host() -> String {
    if let Ok(g) = TARGET_HOST.lock() {
        if let Some(h) = g.as_ref() {
            if !h.trim().is_empty() {
                return h.trim().to_string();
            }
        }
    }
    "10.7.0.1".to_string()
}

pub enum DeviceTunnel {
    Rsd { adapter: AdapterHandle, handshake: idevice::services::rsd::RsdHandshake },
    Lockdown { provider: TcpProvider, pairing_file: PairingFile, legacy: bool },
}

impl DeviceTunnel {
    pub fn route_name(&self) -> &'static str {
        match self {
            DeviceTunnel::Rsd { .. } => "RSD",
            DeviceTunnel::Lockdown { .. } => "Lockdown",
        }
    }

    pub async fn connect_afc(&mut self, log: &Logger) -> Result<idevice::services::afc::AfcClient, String> {
        match self {
            DeviceTunnel::Rsd { adapter, handshake } => handshake
                .connect::<idevice::services::afc::AfcClient>(adapter)
                .await
                .map_err(|e| format!("AFC 连接失败（RSD）: {e:?}")),
            DeviceTunnel::Lockdown { provider, pairing_file, legacy } => {
                let stream = connect_service_lockdown(provider, pairing_file, *legacy, "com.apple.afc", log).await?;
                Ok(idevice::services::afc::AfcClient::new(Idevice::new(stream, "CocoWall")))
            }
        }
    }

    pub async fn connect_installation_proxy(
        &mut self,
        log: &Logger,
    ) -> Result<idevice::services::installation_proxy::InstallationProxyClient, String> {
        match self {
            DeviceTunnel::Rsd { adapter, handshake } => handshake
                .connect::<idevice::services::installation_proxy::InstallationProxyClient>(adapter)
                .await
                .map_err(|e| format!("InstallationProxy 连接失败（RSD）: {e:?}")),
            DeviceTunnel::Lockdown { provider, pairing_file, legacy } => {
                let stream = connect_service_lockdown(provider, pairing_file, *legacy, "com.apple.mobile.installation_proxy", log).await?;
                Ok(idevice::services::installation_proxy::InstallationProxyClient::new(Idevice::new(stream, "CocoWall")))
            }
        }
    }

    pub async fn connect_diagnostics(
        &mut self,
        log: &Logger,
    ) -> Result<idevice::services::diagnostics_relay::DiagnosticsRelayClient, String> {
        match self {
            DeviceTunnel::Rsd { adapter, handshake } => handshake
                .connect::<idevice::services::diagnostics_relay::DiagnosticsRelayClient>(adapter)
                .await
                .map_err(|e| format!("DiagnosticsRelay 连接失败（RSD）: {e:?}")),
            DeviceTunnel::Lockdown { provider, pairing_file, legacy } => {
                let stream = connect_service_lockdown(provider, pairing_file, *legacy, "com.apple.mobile.diagnostics_relay", log).await?;
                Ok(idevice::services::diagnostics_relay::DiagnosticsRelayClient::new(Idevice::new(stream, "CocoWall")))
            }
        }
    }

    /// Raw plist-speaking connection to an arbitrary service, used by the
    /// AirTraffic sync session (no typed client exists for com.apple.atc).
    /// Over RSD the port is looked up in the handshake's service table by
    /// trying the bare and `.shim.remote` names.
    pub async fn connect_plist_service(&mut self, base_name: &str, log: &Logger) -> Result<Idevice, String> {
        match self {
            DeviceTunnel::Rsd { adapter, handshake } => {
                for candidate in [format!("{base_name}.shim.remote"), base_name.to_string()] {
                    if let Some(svc) = handshake.services.get(&candidate) {
                        log.log(format!("隧道：经 RSD 连接 {candidate}（端口 {}）", svc.port));
                        let stream = adapter
                            .connect(svc.port)
                            .await
                            .map_err(|e| format!("RSD 服务端口连接失败: {e:?}"))?;
                        return Ok(Idevice::new(Box::new(stream), "CocoWall"));
                    }
                }
                Err(format!("RSD 服务表中没有 {base_name}（含 .shim.remote）"))
            }
            DeviceTunnel::Lockdown { provider, pairing_file, legacy } => {
                let stream = connect_service_lockdown(provider, pairing_file, *legacy, base_name, log).await?;
                Ok(Idevice::new(stream, "CocoWall"))
            }
        }
    }
}

async fn connect_service_lockdown(
    provider: &TcpProvider,
    pairing_file: &PairingFile,
    legacy: bool,
    service_name: &str,
    log: &Logger,
) -> Result<Box<dyn ReadWrite>, String> {
    log.log(format!("隧道：经 Lockdown 启动 {service_name}…"));
    let stream = provider
        .connect(LOCKDOWN_PORT)
        .await
        .map_err(|e| format!("连接 lockdownd 失败: {e:?}"))?;
    let mut lockdown = LockdownClient::new(stream);
    lockdown
        .start_session(pairing_file)
        .await
        .map_err(|e| format!("Lockdown 会话建立失败: {e:?}"))?;
    let (port, ssl) = lockdown
        .start_service(service_name)
        .await
        .map_err(|e| format!("Lockdown 启动 {service_name} 失败: {e:?}"))?;
    log.log(format!("隧道：{service_name} 已启动于端口 {port}（ssl={ssl}）"));
    let mut idevice = provider
        .connect(port)
        .await
        .map_err(|e| format!("连接服务端口 {port} 失败: {e:?}"))?;
    if ssl {
        idevice
            .start_session(pairing_file, legacy)
            .await
            .map_err(|e| format!("服务 TLS 会话失败: {e:?}"))?;
    }
    idevice.get_socket().ok_or_else(|| "无法取得服务 socket".to_string())
}

/// Establish a tunnel from the raw pairing-file bytes. The file may carry
/// a Lockdown record, Remote Pairing credentials, or both; each route is
/// attempted only when its credential parses.
pub async fn connect_tunnel(pairing_bytes: &[u8], log: &Logger) -> Result<DeviceTunnel, String> {
    let host = target_host();
    let ip: Ipv4Addr = host
        .parse()
        .map_err(|_| format!("目标主机地址无效: {host}"))?;

    let parsed_rp = RpPairingFile::from_bytes(pairing_bytes).ok();
    let parsed_lockdown = PairingFile::from_bytes(pairing_bytes).ok();
    if parsed_rp.is_none() && parsed_lockdown.is_none() {
        return Err("配对文件无效：既没有 Lockdown 记录，也没有 Remote Pairing 凭据。".to_string());
    }

    let mut last_err = String::new();

    if let Some(rpf) = parsed_rp {
        match try_rsd(ip, rpf, log).await {
            Ok(t) => return Ok(t),
            Err(e) => {
                log.log(format!("隧道：RSD 路线失败 — {e}"));
                last_err = e;
            }
        }
    }

    if let Some(pf) = parsed_lockdown {
        match try_lockdown(ip, pf, log).await {
            Ok(t) => return Ok(t),
            Err(e) => {
                log.log(format!("隧道：Lockdown 路线失败 — {e}"));
                last_err = e;
            }
        }
    }

    Err(format!(
        "设备连接失败：{last_err}。请确认回环隧道已开启（本 App 的回环或 LocalDevVPN），且配对文件有效。"
    ))
}

async fn try_rsd(ip: Ipv4Addr, mut rpf: RpPairingFile, log: &Logger) -> Result<DeviceTunnel, String> {
    let addr = SocketAddr::new(IpAddr::V4(ip), RSD_PORT);
    log.log(format!("隧道：尝试 RSD 路线 {addr}（RemotePairing 前门）…"));

    let stream = tokio::time::timeout(Duration::from_secs(5), TcpStream::connect(addr))
        .await
        .map_err(|_| format!("连接 {addr} 超时"))?
        .map_err(|e| format!("连接 {addr} 失败: {e}"))?;

    let socket = RpPairingSocket::new_device(stream);
    let mut rpc = RemotePairingClient::new(socket, "CocoWall");
    // Already-paired devices pass pair-verify without user interaction.
    // If verification fails we must NOT silently start a fresh pair-setup
    // here (no UI is attached to approve a PIN), so the callback returns
    // an empty code and the resulting error tells the user to re-pair.
    rpc.connect(&mut rpf, || async { String::new() })
        .await
        .map_err(|e| format!("RemotePairing 验证失败（可能需要重新配对）: {e:?}"))?;
    log.log("隧道：RemotePairing 验证通过");

    let tunnel_port = rpc
        .create_tcp_listener()
        .await
        .map_err(|e| format!("创建隧道监听失败: {e:?}"))?;
    let mut tunnel_addr = addr;
    tunnel_addr.set_port(tunnel_port);
    let tunnel_stream = tokio::time::timeout(Duration::from_secs(5), TcpStream::connect(tunnel_addr))
        .await
        .map_err(|_| "连接隧道端口超时".to_string())?
        .map_err(|e| format!("连接隧道端口失败: {e}"))?;

    let tunnel = connect_tls_psk_tunnel_native(tunnel_stream, rpc.encryption_key())
        .await
        .map_err(|e| format!("TLS-PSK 隧道握手失败: {e:?}"))?;
    let client_ip: IpAddr = tunnel
        .info
        .client_address
        .parse()
        .map_err(|e| format!("隧道客户端地址无效: {e}"))?;
    let server_ip: IpAddr = tunnel
        .info
        .server_address
        .parse()
        .map_err(|e| format!("隧道服务端地址无效: {e}"))?;
    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;
    log.log(format!("隧道：CDTunnel 已建立（client {client_ip} ↔ device {server_ip}，RSD 端口 {rsd_port}）"));

    let raw = tunnel.into_inner();
    let mut adapter = Adapter::new(Box::new(raw), client_ip, server_ip);
    adapter.set_mss(mtu.saturating_sub(60));
    let mut adapter = adapter.to_async_handle();

    let rsd_stream = adapter
        .connect(rsd_port)
        .await
        .map_err(|e| format!("连接隧道内 RSD 端口失败: {e:?}"))?;
    let handshake = idevice::services::rsd::RsdHandshake::new(rsd_stream)
        .await
        .map_err(|e| format!("RSD 握手失败: {e:?}"))?;
    log.log(format!("隧道：RSD 握手完成，发现 {} 个服务", handshake.services.len()));

    Ok(DeviceTunnel::Rsd { adapter, handshake })
}

async fn try_lockdown(ip: Ipv4Addr, pf: PairingFile, log: &Logger) -> Result<DeviceTunnel, String> {
    log.log(format!("隧道：尝试 Lockdown 路线 {ip}:{LOCKDOWN_PORT}…"));
    let provider = TcpProvider {
        addr: IpAddr::V4(ip),
        scope_id: None,
        pairing_file: pf.clone(),
        label: "CocoWall".to_string(),
    };
    let stream = tokio::time::timeout(Duration::from_secs(3), provider.connect(LOCKDOWN_PORT))
        .await
        .map_err(|_| "连接 lockdownd 超时".to_string())?
        .map_err(|e| format!("连接 lockdownd 失败: {e:?}"))?;
    let mut lockdown = LockdownClient::new(stream);
    let legacy = lockdown
        .start_session(&pf)
        .await
        .map_err(|e| format!("Lockdown 会话建立失败: {e:?}"))?;
    log.log(format!("隧道：Lockdown 会话已建立（legacy={legacy}）"));
    Ok(DeviceTunnel::Lockdown { provider, pairing_file: pf, legacy })
}
