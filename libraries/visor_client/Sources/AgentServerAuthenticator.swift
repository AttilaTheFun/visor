import SwiftUI

/// How a client proves itself to a Visor server, apart from how it
/// reaches it: a transport (HTTP, HTTPS, the computer's SSH) carries
/// the requests, and an authenticator says what goes with each of them.
/// The two shipped: none (a LAN, a personal VPN, SSH alone — the server
/// set to ask nothing), and the password (a bearer, as the connection
/// code carries it). A fork registers its own — a company's SSO whose
/// token goes in a header, for a server behind a proxy that checks it —
/// with a view that gets the credential (`AgentServerAuthenticatorUI`),
/// and the server itself is the same. The credential sits in the
/// record's `secret`, whatever it is.
@MainActor
public protocol AgentServerAuthenticator {
    /// Its id, kept in the record (`AgentServerRecord.authentication`).
    var id: String { get }
    /// What it is called in the sign-in form ("Password").
    var title: String { get }
    /// The headers every request to the server carries, from the record.
    /// Throws `AgentServerError.needsAuthentication` when the user must
    /// sign in first (a token that has expired, a password not typed).
    func headers(for record: AgentServerRecord) async throws -> [String: String]
}

/// No proof asked: the road is the proof (a LAN, a VPN of one's own, the
/// computer's SSH), and the server is set to ask nothing.
public struct NoAuthenticator: AgentServerAuthenticator {
    public nonisolated static let name = "none"
    public let id = NoAuthenticator.name
    public let title = "None"
    public init() {}
    public func headers(for record: AgentServerRecord) async throws -> [String: String] { [:] }
}

/// The server's password, as a bearer token.
public struct PasswordAuthenticator: AgentServerAuthenticator {
    public nonisolated static let name = "password"
    public let id = PasswordAuthenticator.name
    public let title = "Password"
    public init() {}
    public func headers(for record: AgentServerRecord) async throws -> [String: String] {
        ["Authorization": "Bearer " + record.secret]
    }
}
