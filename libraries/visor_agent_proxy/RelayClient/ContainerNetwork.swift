// The container's network as relay-client sets it up, root in its own
// network namespace, over netlink so the image needs neither `ip` nor `nft`
// (the C shim's relay_client_container_network): loopback up and holding
// 198.18.0.1, the default route through loopback from it (so a connection
// anywhere starts rather than failing at once, with an address of its own
// that answers come back to; no dummy interface, which not every kernel
// has); and the nftables table `ip relay_client`, made anew each run, whose
// one chain sends every TCP connection that isn't loopback's to the
// redirect listener. Then /etc/resolv.conf names 127.0.0.1.

import CRelayClientPOSIX
import Foundation

/// Setting up the container's network.
public enum ContainerNetwork {
    /// The table as `nft list ruleset` shows it, for the docs and the logs.
    public static func ruleset(listenerPort: UInt16) -> String {
        """
        table ip relay_client {
            chain output {
                type nat hook output priority -100; policy accept;
                ip daddr 127.0.0.0/8 return
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
        guard relay_client_container_network(listenerPort, FakeAddresses.source, &problem, problem.count) == 0 else {
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
