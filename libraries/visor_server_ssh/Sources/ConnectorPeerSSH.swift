import Foundation
import VisorServer
import VisorSSH

/// The server's SSH to its peers, over VisorSSH's connector.
@MainActor
public final class ConnectorPeerSSH: PeerSSH {
    private let connector = SSHConnector()

    nonisolated public init() {}

    public func newKey() -> Data { SSHConnector.newPrivateKey() }

    public func publicKeyLine(for key: Data) -> String? { SSHConnector.publicKeyLine(forPrivateKey: key, comment: "") }

    public func connect(user: String, host: String, port: Int, key: Data, hostKey: String?) async throws -> any PeerSSHSession {
        do {
            return ConnectorPeerSSHSession(try await connector.connect([SSHHop(user: user, host: host, port: port)], privateKey: key, hostKeys: [hostKey]))
        } catch let error as SSHError {
            throw PeerSSHError(error)
        }
    }
}

/// One connection, as the server's session.
@MainActor
final class ConnectorPeerSSHSession: PeerSSHSession {
    private let connection: SSHConnection
    init(_ connection: SSHConnection) { self.connection = connection }
    var hostKey: String { connection.hostKeys.first ?? "" }
    func attach(command: String) async throws -> Int {
        do { return try await connection.attach(command: command) } catch let error as SSHError { throw PeerSSHError(error) }
    }
    func close() { connection.close() }
}

extension PeerSSHError {
    init(_ error: SSHError) {
        switch error {
        case .unreachable(let why): self = .unreachable(why)
        case .hostKeyChanged: self = .hostKeyChanged
        case .keyRefused: self = .keyRefused
        }
    }
}
