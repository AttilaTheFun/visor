// This server's own SSH: a key of its own, made once and kept with the
// secrets, whose public half goes out with its peer record so the
// computers that take it in authorize it; and, to a peer whose path is
// SSH, a tunnel through the peer's own SSH to its socket file, where
// this server is let in with no password — the same way a device comes
// in. HTTP paths stay as they are; a peer reached over SSH needs none.

import Foundation
import VisorProtocol

extension VisorServer {
    private static let keySecret = "ssh.serverKey"
    /// What reaches a peer's socket file, run there per connection.
    static let peerAttachCommand = "nc -U ~/.visor/server.sock"

    /// The server's private key, raw: made the first time it is asked for.
    private var serverSSHKey: Data? {
        guard let ssh = ServerPlatform.current.ssh else { return nil }
        if let kept = Self.secrets.get(Self.keySecret), let data = Data(base64Encoded: kept), data.count == 32 { return data }
        let key = ssh.newKey()
        Self.secrets.set(Self.keySecret, key.base64EncodedString())
        return key
    }

    /// The server's public key line, for its peers' authorized keys; nil
    /// where the system has no SSH.
    public var ownSSHKey: String? {
        guard let ssh = ServerPlatform.current.ssh, let key = serverSSHKey else { return nil }
        return ssh.publicKeyLine(for: key).map { $0 + " visor-server \(Self.slug(hostName))" }
    }

    /// Where a path's REST side is reached from here: an HTTP path's own
    /// root; an SSH path's through a tunnel opened (and kept) to the
    /// peer, as `http://127.0.0.1:<port>`.
    func base(for path: String) async throws -> String {
        guard let address = SSHAddress(path) else {
            guard let parsed = ServerAddress(path) else { throw PeerSSHError.unreachable("not an address: \(path)") }
            return parsed.root
        }
        if let open = peerTunnels[path] { return open.base }
        guard let ssh = ServerPlatform.current.ssh, let key = serverSSHKey else { throw PeerSSHError.unreachable("no SSH on this system") }
        let hop = address.target
        let setting = "ssh.hostkey.\(hop.user)@\(hop.host):\(hop.port)"
        let known = Self.secrets.get(setting).flatMap { $0.isEmpty ? nil : $0 }
        let session = try await ssh.connect(user: hop.user, host: hop.host, port: hop.port, key: key, hostKey: known)
        if known == nil, !session.hostKey.isEmpty { Self.secrets.set(setting, session.hostKey) }
        do {
            let port = try await session.attach(command: Self.peerAttachCommand)
            let base = "http://127.0.0.1:\(port)"
            peerTunnels[path] = (session, base)
            Self.log("a tunnel to \(hop.host) over SSH")
            return base
        } catch {
            session.close()
            throw error
        }
    }

    /// A path that failed: its tunnel, if any, is closed and forgotten,
    /// so the next try opens a new one.
    func dropTunnel(for path: String) {
        guard let open = peerTunnels.removeValue(forKey: path) else { return }
        open.session.close()
    }
}
