import Combine
import Foundation
import NetworkExtension

/// Owns the NETunnelProviderManager for the bundled loopback tunnel and
/// mirrors the system VPN status for the settings UI.
///
/// There is deliberately no App Group: the manager preferences live in the
/// app's own container and the extension needs no shared state with the app.
@MainActor
final class TunnelManager: ObservableObject {
    enum State { case disconnected, connecting, connected, failed(String) }
    @Published private(set) var state: State = .disconnected
    /// Raw NEVPNStatus of the tunnel connection, kept in sync via
    /// NEVPNStatusDidChange notifications.
    @Published private(set) var status: NEVPNStatus = .invalid

    private static let providerBundleIdentifier = "com.coco.cocowall.Tunnel"
    private static let serverAddress = "10.7.0.1"

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    /// Loads the existing configuration (if any) and publishes its status.
    func refresh() async {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        manager = managers.first(where: {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == Self.providerBundleIdentifier
        }) ?? managers.first
        observeStatus(of: manager)
        apply(status: manager?.connection.status ?? .invalid)
    }

    func connect() async {
        do {
            if manager == nil { await refresh() }
            let m = manager ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.providerBundleIdentifier
            proto.serverAddress = Self.serverAddress
            m.protocolConfiguration = proto
            m.localizedDescription = "CocoWall 回环隧道"
            m.isEnabled = true
            try await m.saveToPreferences()
            try await m.loadFromPreferences()
            manager = m
            observeStatus(of: m)
            try m.connection.startVPNTunnel()
            apply(status: m.connection.status)
            if state == .disconnected { state = .connecting }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        manager?.connection.stopVPNTunnel()
        state = .disconnected
    }

    // MARK: - Status observation

    private func observeStatus(of manager: NETunnelProviderManager?) {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
            statusObserver = nil
        }
        guard let connection = manager?.connection else { return }
        // The observer block runs on the main queue; the explicit Task hop
        // puts the state mutation back on the main actor.
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: connection, queue: .main
        ) { [weak self] note in
            guard let conn = note.object as? NEVPNConnection else { return }
            let newStatus = conn.status
            Task { @MainActor in
                self?.apply(status: newStatus)
            }
        }
    }

    private func apply(status: NEVPNStatus) {
        self.status = status
        switch status {
        case .connected: state = .connected
        case .connecting, .reasserting: state = .connecting
        default: state = .disconnected
        }
    }
}
