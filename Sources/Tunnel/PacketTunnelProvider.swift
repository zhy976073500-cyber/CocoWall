import NetworkExtension
import os.log

/// Loopback tunnel (CocoWall).
///
/// Installs /32 routes for the interface address (10.7.0.2) and the device
/// address (10.7.0.1) only — never the default route — so traffic to the
/// device's own lockdown / RemotePairing front door is routed into this
/// extension, which swaps source and destination and hands the packet back.
/// The packet pair + swap is the invariant; the concrete addresses are
/// configuration (Vellum uses the same 10.7.0.2 / 10.7.0.1 pair).
///
/// Tunnel Info.plist declares the principal class as
/// `$(PRODUCT_MODULE_NAME).PacketTunnelProvider`, i.e. this class.
class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "com.coco.cocowall.tunnel", category: "pump")
    private var pumping = false

    private let deviceAddress = "10.7.0.1"
    private let interfaceAddress = "10.7.0.2"
    private let deviceIP: [UInt8] = [10, 7, 0, 1]
    private let interfaceIP: [UInt8] = [10, 7, 0, 2]

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: deviceAddress)
        let ipv4 = NEIPv4Settings(addresses: [interfaceAddress],
                                  subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [
            NEIPv4Route(destinationAddress: deviceAddress, subnetMask: "255.255.255.255"),
            NEIPv4Route(destinationAddress: interfaceAddress, subnetMask: "255.255.255.255"),
        ]
        settings.ipv4Settings = ipv4
        setTunnelNetworkSettings(settings) { [weak self] error in
            if error == nil {
                self?.pumping = true
                self?.pump()
            }
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        // The in-flight readPackets callback checks `pumping` and does not
        // re-arm the read, so the loop winds down on its own.
        pumping = false
        completionHandler()
    }

    // MARK: - Packet swap pump

    private func pump() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self, self.pumping else { return }
            var out: [Data] = []
            var outProtocols: [NSNumber] = []
            for (i, packet) in packets.enumerated() {
                // IPv4 only; anything else is dropped (the routes only carry v4).
                guard protocols[i].int32Value == AF_INET,
                      let swapped = self.swapped(packet) else { continue }
                out.append(swapped)
                outProtocols.append(protocols[i])
            }
            if !out.isEmpty {
                self.packetFlow.writePackets(out, withProtocols: outProtocols)
            }
            self.pump()
        }
    }

    /// Returns the packet with source and destination exchanged, or nil when
    /// the packet is not part of the loopback pair.
    ///
    /// Only packets travelling between the device address (10.7.0.1) and the
    /// interface address (10.7.0.2) are touched. Anything else is dropped:
    /// the /32 included routes mean such packets should never arrive here,
    /// and writing one back unchanged would send it around the loop again.
    ///
    /// No checksum fixup is needed for a pure address swap. The IPv4 header
    /// checksum is a one's-complement sum over all 16-bit header words, and
    /// the TCP/UDP checksums include a pseudo-header built from the same two
    /// addresses; swapping the two addends leaves both sums unchanged
    /// (addition is commutative), so both checksums stay valid as-is.
    private func swapped(_ packet: Data) -> Data? {
        guard packet.count >= 20, packet[0] >> 4 == 4 else { return nil }
        let src = [UInt8](packet[12..<16])
        let dst = [UInt8](packet[16..<20])
        guard (src == deviceIP && dst == interfaceIP)
                || (src == interfaceIP && dst == deviceIP) else { return nil }
        var p = packet
        p.replaceSubrange(12..<16, with: dst)
        p.replaceSubrange(16..<20, with: src)
        return p
    }
}
