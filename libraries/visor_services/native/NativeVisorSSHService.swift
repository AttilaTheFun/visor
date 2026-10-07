// SSH for the client, over VisorSSH: this device's key, made once and
// kept with the secrets, and each connection as the service promises it.

import Foundation
import VisorSSH

@MainActor
public final class NativeVisorSSHService: VisorSSHService {
    private static let keySetting = "ssh.key"
    private let connector = SSHConnector()

    public init() {}

    /// The device's key: read from the secrets, made and kept the first time.
    private func privateKey() -> Data {
        if let kept = VisorHost.settings?.secret(key: Self.keySetting), let data = Data(base64Encoded: kept), data.count == 32 {
            return data
        }
        let key = SSHConnector.newPrivateKey()
        VisorHost.settings?.setSecret(key: Self.keySetting, value: key.base64EncodedString())
        return key
    }

    public func publicKey() -> String {
        SSHConnector.publicKeyLine(forPrivateKey: privateKey(), comment: "visor") ?? ""
    }

    public func connect(_ route: [VisorSSHHop], hostKeys: [String?]) async throws -> any VisorSSHSession {
        do {
            let connection = try await connector.connect(route.map { SSHHop(user: $0.user, host: $0.host, port: $0.port) },
                                                         privateKey: privateKey(), hostKeys: hostKeys)
            return NativeVisorSSHSession(connection)
        } catch let error as SSHError {
            throw VisorSSHError(error)
        }
    }
}

/// One connection, as the service's session.
@MainActor
final class NativeVisorSSHSession: VisorSSHSession {
    private let connection: SSHConnection
    init(_ connection: SSHConnection) { self.connection = connection }
    var hostKeys: [String] { connection.hostKeys }
    func forward(toPort port: Int) async throws -> Int { try await Self.mapping { try await connection.forward(toPort: port) } }
    func attach(command: String) async throws -> Int { try await Self.mapping { try await connection.attach(command: command) } }
    func close() { connection.close() }

    private static func mapping<T>(_ work: () async throws -> T) async throws -> T {
        do { return try await work() } catch let error as SSHError { throw VisorSSHError(error) }
    }
}

extension VisorSSHError {
    init(_ error: SSHError) {
        switch error {
        case .unreachable(let why): self = .unreachable(why)
        case .hostKeyChanged: self = .hostKeyChanged
        case .keyRefused: self = .keyRefused
        }
    }
}
