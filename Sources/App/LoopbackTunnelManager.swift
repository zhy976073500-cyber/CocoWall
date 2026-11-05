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

    /// run #167：签名被挡标志——`loadAllFromPreferences` /
    /// `saveToPreferences` 报 NEConfigurationErrorDomain Code 10
    /// "permission denied" 时置位，说明当前签名未授予
    /// NetworkExtension packet-tunnel-provider 权限，内置回环
    /// 在此签名下永远起不来（不是用户点拒绝、不是系统版本）。
    /// `signingBlockedIsEnterprise` 为真 = 描述文件是企业
    /// 分发（ProvisionsAllDevices），即 Sage 说的共享企业证书
    /// 情形；吊销本身 App 内无法直接核验（系统在启动时才做
    /// 吊销校验），此处只断言“企业证书 + 无回环权限”。
    @Published private(set) var signingBlocked = false
    @Published private(set) var signingBlockedIsEnterprise = false

    /// run #168：是否在 LiveContainer 内以客 App 运行。LiveContainer
    /// 是启动器不是安装器：客 App 不真正安装，进程可执行文件仍是
    /// 宿主 LiveContainer（客可执行文件只是被 dlopen，不 exec），
    /// 故内置回环在此从原理上不可用——客 entitlements 不作用于
    /// 宿主、App 扩展不支持、tunnel appex 从未向系统注册。
    /// 注意不能用 Bundle.main 判断：LiveContainer 会把 mainBundle
    /// patch 成客 bundle，bundleIdentifier / bundlePath 看着都是
    /// CocoWall；只能看进程本身的可执行文件路径。
    @Published private(set) var isLiveContainerGuest = LoopbackTunnelManager.isRunningInsideLiveContainer()

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
            // 读配置成功 = 系统允许本签名访问 VPN 偏好设置，
            // 此前若因 Code 10 置过位，在此清掉。
            signingBlocked = false
        } catch {
            lastError = "读取 VPN 配置失败：\(error.localizedDescription)"
            // run #167：Code 10 即签名无回环权限，置位供两页
            // 的兜底卡片（LoopbackSigningBlockedCard）渲染。
            if Self.isPermissionDenied(error) {
                noteSigningBlocked()
            }
        }
    }

    /// NEConfigurationErrorDomain Code 10 "permission denied"——
    /// 官方文档与生态经验均指向 entitlements / 描述文件未授
    /// 权，而非用户拒绝或系统版本。
    private static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "NEConfigurationErrorDomain" && nsError.code == 10
    }

    private func noteSigningBlocked() {
        signingBlocked = true
        signingBlockedIsEnterprise = Self.isEnterpriseProvisioned()
    }

    /// 描述文件是否为企业分发：embedded.mobileprovision 内
    /// `ProvisionsAllDevices == true` 即企业证书签名（共享
    /// 签名店常用）；开发 / Ad Hoc 描述文件带 ProvisionedDevices
    /// 列表、App Store 描述文件无此键，均返回 false。无签名
    /// 的 CI 产物无此文件，返回 false（走通用文案）。
    static func isEnterpriseProvisioned() -> Bool {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let xmlStart = data.range(of: Data("<?xml".utf8)),
              let plistEnd = data.range(of: Data("</plist>".utf8)) else {
            return false
        }
        let plistData = data[xmlStart.lowerBound..<plistEnd.upperBound]
        guard let plist = try? PropertyListSerialization.propertyList(
            from: plistData, format: nil) as? [String: Any] else {
            return false
        }
        return plist["ProvisionsAllDevices"] as? Bool == true
    }

    /// 是否在 LiveContainer 内以客 App 运行（run #168）。
    /// 判定只看进程本身：正常安装时进程可执行文件即主 bundle
    /// 的可执行文件（…/CocoWall.app/CocoWall）；LiveContainer
    /// 内进程可执行文件是宿主（…/LiveContainer.app/LiveContainer），
    /// 而主 bundle 的可执行文件是客的 CocoWall。两档判定：
    /// ① 进程路径或进程名含 LiveContainer；② 进程可执行文件
    /// 名与主 bundle 可执行文件名不一致且后者是 CocoWall（防
    /// 调试器等启动路径花样造成的误判）。
    static func isRunningInsideLiveContainer() -> Bool {
        let processName = ProcessInfo.processInfo.processName
        if processName.localizedCaseInsensitiveContains("LiveContainer") {
            return true
        }
        guard let execPath = ProcessInfo.processInfo.arguments.first else {
            return false
        }
        if execPath.localizedCaseInsensitiveContains("LiveContainer") {
            return true
        }
        guard let bundleExec = Bundle.main.executablePath else {
            return false
        }
        let execName = URL(fileURLWithPath: execPath).lastPathComponent
        let bundleExecName = URL(fileURLWithPath: bundleExec).lastPathComponent
        return execName != bundleExecName
            && !execName.localizedCaseInsensitiveContains("CocoWall")
            && bundleExecName.localizedCaseInsensitiveContains("CocoWall")
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
                // 启动成功 = 签名有回环权限，清掉此前置位。
                signingBlocked = false
            } catch {
                lastError = "开启内置回环失败：\(error.localizedDescription)"
                // run #167：Code 10 即签名无回环权限，置位供两页
                // 的兜底卡片（LoopbackSigningBlockedCard）渲染。
                if Self.isPermissionDenied(error) {
                    noteSigningBlocked()
                }
            }
        }
    }

    func stop() {
        lastError = nil
        manager?.connection.stopVPNTunnel()
    }
}
