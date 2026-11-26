// Who a request relayed by a front on this computer came from. The
// tailnet's way in is `tailscale serve`, proxying to 127.0.0.1:7433
// (docs/DEVELOPMENT.md): every client on it reaches the server from
// loopback, which on its own is this computer, never counted for wrong
// passwords and on whichever paths are off. tailscale serve names the
// client in X-Forwarded-For (set whole, the one address: Tailscale's
// ipn/ipnlocal/serve.go, addProxyForwardedHeaders), so a connection from
// loopback with that header is taken for that client: its wrong passwords
// are counted by the client's address (PasswordThrottle), and one from a
// tailnet's address is let in only while the VPN path is on, as if it had
// come straight here.
//
// A process on this computer could put anything in the header: it is
// trusted already (from loopback without the header it is never counted),
// so at most it counts against an address, or keeps itself out. From
// anywhere but loopback the header is never read: anyone on the network
// could name anyone in it.

import Foundation
import VisorSystem

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

    /// Whether `address` is a tailnet's: 100.64.0.0/10, or Tailscale's
    /// fd7a:115c:a1e0::/48 (net/tsaddr's TailscaleULARange).
    static func isTailnet(_ address: String) -> Bool {
        var address = address.trimmingCharacters(in: .whitespaces).lowercased()
        if address.hasPrefix("["), address.hasSuffix("]") { address = String(address.dropFirst().dropLast()) }
        address = String(address.split(separator: "%", omittingEmptySubsequences: false).first ?? "")
        guard address.contains(":") else { return NetworkAddress.kind(of: address, on: "") == .vpn }
        guard let groups = PasswordThrottle.groups(ipv6: address) else { return false }
        if groups[0..<5].allSatisfy({ $0 == 0 }), groups[5] == 0xffff {
            let v4 = [groups[6] >> 8, groups[6] & 0xff, groups[7] >> 8, groups[7] & 0xff].map { String($0) }.joined(separator: ".")
            return NetworkAddress.kind(of: v4, on: "") == .vpn
        }
        return groups[0] == 0xfd7a && groups[1] == 0x115c && groups[2] == 0xa1e0
    }
}
