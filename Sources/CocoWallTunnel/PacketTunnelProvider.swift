import Foundation
import NetworkExtension

/// Minimal loopback packet-tunnel provider (run #125).
///
/// Brings up a point-to-point tunnel interface whose only job is to make
/// the device's own RemoteServiceDiscovery endpoint reachable from
/// on-device apps: packets the network stack routes toward the peer
/// address (10.7.0.1/32, the address the Rust core dials for RSD on
/// port 49152) have their IPv4 source/destination swapped and are
/// written straight back into the packet flow, so they arrive as
/// inbound packets addressed to this device and are delivered to the
/// local listener. Replies take the same hairpin in reverse. Swapping
/// the two addresses leaves both the IP header checksum and the TCP
/// pseudo-header checksum unchanged (the same words are summed), so
/// no checksum fixup is needed.
///
/// The shape follows the ecosystem-verified LocalDevVPN design
/// (jkcoxson/LocalDevVPN, TunnelProv — itself after StikJIT): a
/// dedicated interface address on a different /32 (10.7.1.1) so the
/// peer address is never a local address, a single included route for
/// the peer /32, and the default route excluded so no other traffic
/// enters the tunnel. Implemented fresh for CocoWall; no code copied.
final class PacketTunnelProvider: NEPacketTunnelProvider {

    /// Configuration keys shared with the app side
    /// (`LoopbackTunnelManager`), mirroring LocalDevVPN's.
    static let ifaceIPConfigurationKey = "TunnelIfaceIP"
    static let peerIPConfigurationKey = "TunnelPeerIP"

    private var ifaceEndpoint = CIDREndpoint("10.7.1.1/32", defaultPrefix: 24)
    private var peerEndpoint = CIDREndpoint("10.7.0.1/32", defaultPrefix: 32)

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        let providerConfiguration =
            (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        if let raw = options?[PacketTunnelProvider.ifaceIPConfigurationKey] as? String
            ?? providerConfiguration?[PacketTunnelProvider.ifaceIPConfigurationKey] as? String {
            ifaceEndpoint = CIDREndpoint(raw, defaultPrefix: 24)
        }
        if let raw = options?[PacketTunnelProvider.peerIPConfigurationKey] as? String
            ?? providerConfiguration?[PacketTunnelProvider.peerIPConfigurationKey] as? String {
            peerEndpoint = CIDREndpoint(raw, defaultPrefix: 32)
        }

        let ipv4 = NEIPv4Settings(addresses: [ifaceEndpoint.ip],
                                  subnetMasks: [ifaceEndpoint.subnetMask])
        // Only the peer endpoint is routed into the tunnel; everything
        // else keeps using the normal interfaces.
        ipv4.includedRoutes = [
            NEIPv4Route(destinationAddress: peerEndpoint.ip,
                        subnetMask: peerEndpoint.subnetMask)
        ]
        ipv4.excludedRoutes = [.default()]

        // tunnelRemoteAddress is display-only; routing comes from the
        // IPv4 settings above.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: peerEndpoint.ip)
        settings.ipv4Settings = ipv4

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                completionHandler(error)
                return
            }
            self?.pumpPackets()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    /// Read outbound packets, swap IPv4 src/dst, write them back as
    /// inbound, repeat. Non-IPv4 packets (and runt frames) pass through
    /// unmodified.
    private func pumpPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self else { return }
            var out = packets
            for i in out.indices
            where protocols[i].int32Value == AF_INET && out[i].count >= 20 {
                out[i].withUnsafeMutableBytes { raw in
                    guard let words = raw.baseAddress?
                        .assumingMemoryBound(to: UInt32.self) else { return }
                    // IPv4 header words 3/4 are source/destination.
                    let src = words[3]
                    words[3] = words[4]
                    words[4] = src
                }
            }
            self.packetFlow.writePackets(out, withProtocols: protocols)
            self.pumpPackets()
        }
    }
}

/// An "a.b.c.d/prefix" endpoint. The prefix defaults per call site
/// (interface 24, peer 32) when the string carries no slash, matching
/// LocalDevVPN's CIDREndpoint behaviour.
private struct CIDREndpoint {
    let ip: String
    let prefix: Int

    init(_ raw: String, defaultPrefix: Int) {
        let parts = raw.split(separator: "/", maxSplits: 1)
        ip = parts.first.map(String.init) ?? raw
        if parts.count == 2, let parsed = Int(parts[1]), (0...32).contains(parsed) {
            prefix = parsed
        } else {
            prefix = defaultPrefix
        }
    }

    var subnetMask: String {
        guard prefix > 0 else { return "0.0.0.0" }
        let bits = UInt32.max << (32 - prefix)
        return [24, 16, 8, 0]
            .map { String((bits >> $0) & 0xff) }
            .joined(separator: ".")
    }
}
