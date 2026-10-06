// A server reached over SSH: the computer's `sshd` is the road in,
// authenticated by this device's key, and the server itself is reached
// on its own loopback through a forwarded port. Everything else is the
// HTTP server over that port — the sign-in with the password, the live
// channel, the one-shot calls, the polling fallback. Nothing has to be
// open on the computer's network but SSH, and nothing is added to the
// server.

import VisorProtocol
import VisorServices

extension HTTPAgentServer {
    /// The server's port on the computer's loopback.
    static let serverPort = Int(Envelope.defaultPort)

    /// Opens the SSH connection along the address's route — each hop's
    /// host key kept the first time and compared after — and forwards a
    /// port here to the server; `address` is then the tunnel's.
    func openTunnel(_ address: SSHAddress) async throws {
        closeTunnel()
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
            throw AgentServerError.needsAuthentication
        } catch VisorSSHError.unreachable(let why) {
            throw AgentServerError.message("\(address.target.host) was not reached over SSH: \(why)")
        }
        for (index, hop) in route.enumerated() where known[index] == nil && session.hostKeys.count > index && !session.hostKeys[index].isEmpty {
            VisorHost.settings?.set(key: SSHAddress.hostKeySetting(hop), value: session.hostKeys[index])
        }
        do {
            let port = try await session.forward(toPort: Self.serverPort)
            tunnelSession = session
            tunnel = ServerAddress("http://127.0.0.1:\(port)")
        } catch {
            session.close()
            throw AgentServerError.message("\(address.target.host) could not forward a port: \(error)")
        }
    }

    func closeTunnel() {
        tunnelSession?.close()
        tunnelSession = nil
        tunnel = nil
    }
}
