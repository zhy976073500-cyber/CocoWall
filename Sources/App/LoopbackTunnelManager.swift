import Foundation
import NetworkExtension

/// Installs and drives CocoWall's built-in loopback VPN configuration
/// (run #125) — the in-app replacement for the external LocalDevVPN
/// app. The configuration points at the embedded packet-tunnel
/// extension (`CocoWallTunnel.appex`, bundle id
/// `com.coco.cocowall.tunnel`), which hairpins traffic for the RSD
/// endpoint 10.7.0.1 back into the device. Address plan mirrors the
/// ecosystem-verified LocalDevVPN defaults: the tunnel interface
/// itself is 10.7.1.1/32, the routed peer is 10.7.0.1/32 — the same
/// host the Rust core already dials, so nothing below the UI layer
/// changes.
@MainActor
final class LoopbackTunnelManager: ObservableObject {

    static let providerBundleIdentifier = "com.coco.cocowall.tunnel"
    static let ifaceIP = "10.7.1.1/32"
    static let peerIP = "10.7.0.1/32"

    /// The one shared instance (run #127). The settings-page row and
    /// the wallpaper-page status area drive the same saved VPN
    /// configuration, so both must observe and control a single
    /// manager: each private instance filters NEVPNStatus change
    /// notifications against its own connection object, and two
    /// instances can disagree about the tunnel's state.
    static let shared = LoopbackTunnelManager()

    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var isBusy = false
    @Published var lastError: String?

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let connection = note.object as? NEVPNConnection else { return }
            Task { @MainActor [weak self] in
                guard let self = self,
                      connection === self.manager?.connection else { return }
                self.status = connection.status
            }
        }
        Task { await reload() }
    }

    deinit {
        if let statusObserver = statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    var isActive: Bool {
        status == .connected || status == .connecting || status == .reasserting
    }

    var statusText: String {
        switch status {
        case .connected: return "内置回环已连接"
        case .connecting: return "内置回环连接中…"
        case .disconnecting: return "内置回环断开中…"
        case .reasserting: return "内置回环重连中…"
        case .disconnected: return "内置回环未开启"
        case .invalid: return "内置回环未配置"
        @unknown default: return "内置回环状态未知"
        }
    }

    /// Finds our saved configuration (if the user has installed it
    /// before) and adopts its live status.
    func reload() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == LoopbackTunnelManager.providerBundleIdentifier
            }
            status = manager?.connection.status ?? .invalid
        } catch {
            lastError = "读取 VPN 配置失败：\(error.localizedDescription)"
        }
    }

    func toggle() {
        if isActive {
            stop()
        } else {
            start()
        }
    }

    /// Creates (first run — iOS shows its own "add VPN configuration"
    /// consent prompt) or updates the configuration, then starts the
    /// tunnel.
    func start() {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        Task {
            defer { isBusy = false }
            do {
                let mgr = manager ?? NETunnelProviderManager()
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = LoopbackTunnelManager.providerBundleIdentifier
                proto.serverAddress = "10.7.0.1"
                proto.providerConfiguration = [
                    "TunnelIfaceIP": LoopbackTunnelManager.ifaceIP,
                    "TunnelPeerIP": LoopbackTunnelManager.peerIP,
                ]
                mgr.protocolConfiguration = proto
                mgr.localizedDescription = "CocoWall 内置回环"
                mgr.isEnabled = true
                try await mgr.saveToPreferences()
                // A manager must be reloaded after a save before its
                // connection object is usable.
                try await mgr.loadFromPreferences()
                manager = mgr
                status = mgr.connection.status
                try mgr.connection.startVPNTunnel()
            } catch {
                lastError = "开启内置回环失败：\(error.localizedDescription)"
            }
        }
    }

    func stop() {
        lastError = nil
        manager?.connection.stopVPNTunnel()
    }
}
