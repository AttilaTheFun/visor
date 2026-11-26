// Who a request relayed by a front on this computer came from. The
// tailnet's way in is `tailscale serve`, proxying to 127.0.0.1:7433
// (docs/DEVELOPMENT.md): every client on it reaches the server from
// loopback, which on its own is this computer, never counted for wrong
// passwords. tailscale serve names the client in X-Forwarded-For (set
// whole, the one address: Tailscale's ipn/ipnlocal/serve.go,
// addProxyForwardedHeaders), so a connection from loopback with that
// header has its wrong passwords counted by the client's address
// (PasswordThrottle). The LAN and VPN switches aren't asked of it: serving
// to the tailnet is the owner's own choice.
//
// A process on this computer could put anything in the header: it is
// trusted already (from loopback without the header it is never counted),
// so at most it counts against an address, or keeps itself out. From
// anywhere but loopback the header is never read: anyone on the network
// could name anyone in it.

import Foundation

enum ForwardedFor {
    /// The address a request or an upgrade (its headers, names in lower
    /// case) is taken as coming from: the client a front on this computer
    /// names, else the connection's own address.
    static func client(peer: String?, headers: [String: String]) -> String? {
        relayed(peer: peer, headers: headers) ?? peer
    }

    /// The client a front on this computer names: X-Forwarded-For's
    /// right-most entry, the one the front itself added (any before it are
    /// what the client said). Nil but on a connection from loopback.
    static func relayed(peer: String?, headers: [String: String]) -> String? {
        guard isLoopback(peer), let header = headers["x-forwarded-for"],
              let last = header.split(separator: ",").last?.trimmingCharacters(in: .whitespaces), !last.isEmpty else { return nil }
        return last
    }

    /// Whether `address` is this computer's own: loopback, IPv4's or IPv6's
    /// (`::1`, `::ffff:127.0.0.1`); the addresses the throttle keys none.
    static func isLoopback(_ address: String?) -> Bool {
        guard let address, !address.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return PasswordThrottle.key(address) == nil
    }
}
