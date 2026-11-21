// The container's network as relay-client sets it up, root in its own
// network namespace, over netlink so the image needs neither `ip` nor `nft`
// (the C shim's relay_client_container_network): loopback up and holding
// 198.18.0.1, the default route through loopback from it (so a connection
// anywhere starts rather than failing at once, with an address of its own
// that answers come back to; no dummy interface, which not every kernel
// has); and the nftables table `ip relay_client`, made anew each run, whose
// one chain sends every TCP connection that isn't loopback's to the
// redirect listener. Then /etc/resolv.conf names 127.0.0.1.
//
// What isn't redirected is `excluded` (127.0.0.0/8), decided here and handed
// to the C that writes the rule, so the rule, its text and the redirect
// listener's own refusal are the same and `isRedirected` tests it: the
// loopback forwards (`--forward 7434=/run/visor/driver.sock`, Visor's
// driver) and DNS listen there, and must never go to agent-proxy.

import CRelayClientPOSIX
import Foundation

/// Setting up the container's network.
public enum ContainerNetwork {
    /// The network the chain returns for, never redirected: loopback's.
    public static let excluded = (network: [UInt8]([127, 0, 0, 0]), prefix: 8)

    /// A prefix's mask, 4 bytes (8: 255.0.0.0).
    public static func mask(prefix: Int) -> [UInt8] {
        let length = min(max(prefix, 0), 32)
        let bits: UInt32 = length == 0 ? 0 : UInt32.max << UInt32(32 - length)
        return [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: bits >> $0) }
    }

    /// Whether the chain sends a TCP connection to `address` (IPv4, dotted)
    /// to the redirect listener: every address but `excluded`'s. Anything
    /// that isn't an IPv4 address is taken as redirected.
    public static func isRedirected(_ address: String) -> Bool {
        let fields = address.split(separator: ".", omittingEmptySubsequences: false)
        let parts = fields.compactMap { UInt8($0) }
        guard fields.count == 4, parts.count == 4 else { return true }
        let mask = mask(prefix: excluded.prefix)
        return (0..<4).contains { parts[$0] & mask[$0] != excluded.network[$0] & mask[$0] }
    }

    /// The table as `nft list ruleset` shows it, for the docs and the logs.
    public static func ruleset(listenerPort: UInt16) -> String {
        let network = excluded.network.map(String.init).joined(separator: ".")
        return """
            table ip relay_client {
                chain output {
                    type nat hook output priority -100; policy accept;
                    ip daddr \(network)/\(excluded.prefix) return
                    meta l4proto tcp redirect to :\(listenerPort)
                }
            }

            """
    }

    /// What /etc/resolv.conf says.
    public static let resolvConf = "# relay-client: names are asked of it, and relayed to agent-proxy.\nnameserver 127.0.0.1\n"

    /// Sets the network up and writes `resolvConf` to `resolver`; what went
    /// wrong, or nil. It can be run again.
    public static func setUp(listenerPort: UInt16, resolver: URL = URL(fileURLWithPath: "/etc/resolv.conf")) -> String? {
        var problem = [CChar](repeating: 0, count: 256)
        let network = excluded.network, mask = mask(prefix: excluded.prefix)
        guard relay_client_container_network(listenerPort, FakeAddresses.source, network, mask, &problem, problem.count) == 0 else {
            return String(decoding: problem.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        do {
            // In place: the file may be a mount of its own.
            let handle = try FileHandle(forWritingTo: resolver)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(resolvConf.utf8))
        } catch {
            return "\(resolver.path): \(error.localizedDescription)"
        }
        return nil
    }
}
