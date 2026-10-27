import NetworkExtension

/// Loopback tunnel: installs /32 routes for the interface address (10.7.0.2)
/// and the device address (10.7.0.1) only — never the default route — then
/// swaps source/destination on packets between the two so the app can reach
/// the device's own lockdown / RemotePairing services on-device.
/// Packet pump implementation lands in M1 with the idevice bridge.
class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.7.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.7.0.2"], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [
            NEIPv4Route(destinationAddress: "10.7.0.1", subnetMask: "255.255.255.255"),
            NEIPv4Route(destinationAddress: "10.7.0.2", subnetMask: "255.255.255.255"),
        ]
        settings.ipv4Settings = ipv4
        setTunnelNetworkSettings(settings) { error in
            // TODO: start the packet swap pump here.
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
