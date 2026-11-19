// What an agent's egress may reach (NCH's review of #414; Logan, 2026-11-14:
// "open egress" means the internet). Never this Mac: its own interfaces'
// addresses, loopback, link-local and the rest, however a name or an IPv6
// form carries them. Not its networks either, unless server.json's
// `agentProxy.egressAllow` lists them: the private ranges (10/8, 172.16/12,
// 192.168/16), the tailnet's and CGNAT's 100.64/10, and IPv6's fc00::/7 (a
// tailnet's fd7a:115c:a1e0::/48 among them). Whether LAN and tailnet peers
// should be reachable is Logan's to say: either answer is a line of config.
// Each address a name resolves to is judged before it is connected to
// (agent_proxy_connect_tcp_egress), so what is judged is what is reached.
// A destination listed by name may carry a pin (`nas.local:443@192.168.1.20`,
// `nas.local:443@192.168.1.0/24`; NCH's review of #414): what the name
// resolves to must then fall within it, so a name rebound to another of the
// network's addresses reaches nothing. A destination listed both with a pin
// and without is pinned.

import CAgentProxyPOSIX
import Foundation

/// The egress allowlist, and the connection it permits.
public struct EgressPolicy: Sendable, Equatable {
    /// The CIDRs (or bare addresses) of the private ranges that may be reached.
    public private(set) var ranges: [String] = []
    /// The destinations, as a CONNECT names them (`host:port`, lower case, an
    /// IPv6 address bracketed), that may reach a private address.
    public private(set) var destinations: Set<String> = []
    /// The destinations pinned, each to the CIDRs (or addresses) it may
    /// resolve to.
    public private(set) var pins: [String: [String]] = [:]
    /// What `egressAllow` held that is neither, passed over.
    public private(set) var rejected: [String] = []

    /// `allow`'s entries: a CIDR (`10.0.0.0/8`, `fd7a:115c:a1e0::/48`), a bare
    /// address (`192.168.1.20`), or a destination (`nas.local:443`,
    /// `[fd7a::1]:22`), pinned or not (`nas.local:443@192.168.1.0/24`). None:
    /// the internet alone.
    public init(allow: [String] = []) {
        for entry in allow.map({ $0.trimmingCharacters(in: .whitespaces) }) where !entry.isEmpty {
            if agent_proxy_cidr_valid(entry) == 1 {
                ranges.append(entry)
            } else if let at = entry.lastIndex(of: "@") {
                let pin = String(entry[entry.index(after: at)...])
                guard let destination = EgressProxy.destination(String(entry[..<at])), agent_proxy_cidr_valid(pin) == 1 else {
                    rejected.append(entry)
                    continue
                }
                destinations.insert(Self.key(destination))
                pins[Self.key(destination), default: []].append(pin)
            } else if let destination = EgressProxy.destination(entry) {
                destinations.insert(Self.key(destination))
            } else {
                rejected.append(entry)
            }
        }
    }

    private static func key(_ destination: EgressProxy.Destination) -> String {
        let host = destination.host.lowercased()
        return host.contains(":") ? "[\(host)]:\(destination.port)" : "\(host):\(destination.port)"
    }

    /// Whether `destination` was listed by name, so it may reach a private address.
    public func lists(_ destination: EgressProxy.Destination) -> Bool { destinations.contains(Self.key(destination)) }

    /// Whether an address (as text) may be reached by a destination listed or not.
    public func allows(address: String, listed: Bool = false) -> Bool {
        agent_proxy_address_allowed(address, ranges.joined(separator: "\n"), listed ? 1 : 0) == 1
    }

    /// Whether `destination` may reach an address (as text) it resolved to:
    /// listed or not, and within its pin if it has one.
    public func allows(address: String, for destination: EgressProxy.Destination) -> Bool {
        agent_proxy_address_allowed_pinned(address, ranges.joined(separator: "\n"), lists(destination) ? 1 : 0, pin(destination)) == 1
    }

    /// `destination`'s pin, its CIDRs a line each; empty for none.
    private func pin(_ destination: EgressProxy.Destination) -> String {
        pins[Self.key(destination)]?.joined(separator: "\n") ?? ""
    }

    /// A connection to `destination` within the policy: -1 with errno
    /// EACCES when every address it resolves to is refused.
    public func connect(_ destination: EgressProxy.Destination) -> Int32 {
        agent_proxy_connect_tcp_egress_pinned(destination.host, destination.port, ranges.joined(separator: "\n"), lists(destination) ? 1 : 0,
                                              pin(destination))
    }
}
