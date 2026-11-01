// This server as its clients and its agents know it: its id, its own
// addresses, and the connection codes made of them.

import Foundation
import VisorProtocol

extension VisorServer {
    /// This server's id: unique among servers, kept in its settings.
    public var id: String { settings.serverID }

    /// This server's own addresses, as clients read them: its network
    /// paths that are on — the proxy's URL, `http(s)://` on each address
    /// of the LAN and the VPN, `ssh://user@` on each address.
    public var ownAddresses: [String] {
        var out: [String] = []
        let set = settings.publicAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.proxyEnabled, !set.isEmpty { out.append(set) }
        // Behind a front: its paths, not this container's own.
        if !settings.frontPaths.isEmpty { return out + settings.frontPaths }
        return out + httpPaths + sshPaths
    }

    /// The server's connection codes: the one its QR code shows, and one
    /// leading with each kind of path it has (`GET /api/codes`). What the
    /// menu bar app shows and what a client's computer settings show are
    /// these, so a code read off either adds the computer the same way.
    public var connectionCodes: ConnectionCodes? { connectionCode.map(ConnectionCodes.init) }
}
