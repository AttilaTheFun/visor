// A server reached over SSH: the computer's `sshd` is the path in,
// authenticated by this device's key, and the server itself is reached
// through it — at its socket file, where a connection as the user is
// already signed in and no password is asked (`nc -U` run on the
// computer for each connection), or, where the server does not serve
// that, at its port on the computer's loopback, with the password.
// Everything else is the HTTP server over the port here — the sign-in,
// the live channel, the one-shot calls, the polling fallback. Nothing
// has to be open on the computer's network but SSH, and nothing is
// added to the server.

import VisorProtocol
import VisorServices

extension VisorAgentServer {
    /// The server's port on the computer's loopback.
    static let serverPort = Int(Envelope.defaultPort)
    /// What reaches the server's socket file on the computer, run there
    /// for each connection (`VisorServer.socketPath`).
    static let attachCommand = "nc -U ~/.visor/server.sock"

    /// Opens the SSH connection along the address's route — each hop's
    /// host key kept the first time and compared after — and a port here
    /// that reaches the server's socket file; `address` is then the
    /// tunnel's. `fallBackToPort` reaches the port instead.
    func openTunnel(_ address: SSHAddress) async throws {
        closeTunnel()
        tunnelOpenings += 1
        let opening = tunnelOpenings
        guard let ssh = VisorHost.ssh else { throw AgentServerError.message("This app cannot reach a computer over SSH") }
        let route = address.route
        let known: [String?] = route.map { hop in
            let kept = VisorHost.settings?.get(key: SSHAddress.hostKeySetting(hop)) ?? ""
            return kept.isEmpty ? nil : kept
        }
        let session: any VisorSSHSession
        do {
            session = try await ssh.connect(route.map { VisorSSHHop(user: $0.user, host: $0.host, port: $0.port) }, hostKeys: known)
        } catch VisorSSHError.hostKeyChanged {
            throw AgentServerError.message("A host key on the way to \(address.target.host) has changed. If the computer was reinstalled, forget it here and add it again.")
        } catch VisorSSHError.keyRefused {
            // Not a sign-in to redo: another path may let the device in
            // (and authorize its key for next time).
            throw AgentServerError.message("\(address.target.host) does not know this device's SSH key yet")
        } catch VisorSSHError.unreachable(let why) {
            throw AgentServerError.message("\(address.target.host) was not reached over SSH: \(why)")
        }
        for (index, hop) in route.enumerated() where known[index] == nil && session.hostKeys.count > index && !session.hostKeys[index].isEmpty {
            VisorHost.settings?.set(key: SSHAddress.hostKeySetting(hop), value: session.hostKeys[index])
        }
        // A sign-in that began after this one owns the tunnel now: this
        // connection is not left open with nothing to carry.
        guard opening == tunnelOpenings else {
            session.close()
            throw AgentServerError.message("Signing in again")
        }
        do {
            let port = try await session.attach(command: Self.attachCommand)
            tunnelSession = session
            tunnel = ServerAddress("http://127.0.0.1:\(port)")
        } catch {
            session.close()
            throw AgentServerError.message("\(address.target.host) could not open a channel: \(error)")
        }
    }

    /// The server's port on the computer's loopback, with the password,
    /// for a server that does not serve its socket file (SSH clients not
    /// let in without a password, an older server, a system without
    /// socket files, no `nc` there).
    func fallBackToPort() async throws {
        guard let session = tunnelSession else { throw AgentServerError.message("Not connected over SSH") }
        let port = try await session.forward(toPort: Self.serverPort)
        tunnel = ServerAddress("http://127.0.0.1:\(port)")
    }

    func closeTunnel() {
        tunnelSession?.close()
        tunnelSession = nil
        tunnel = nil
    }
}
