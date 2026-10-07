import Foundation

/// SSH, as the system gives it to the server, for reaching its peers
/// through their own SSH: a connection as a user with the server's key,
/// and from it a port here that runs a command there (the peer's socket
/// file is what the command reaches). A system without it (Windows)
/// gives none, and peers are reached over HTTP alone.
@MainActor
public protocol PeerSSH: AnyObject, Sendable {
    /// A new Ed25519 private key, raw: the server keeps it with its secrets.
    func newKey() -> Data
    /// The public half of a key, as an `authorized_keys` line.
    func publicKeyLine(for key: Data) -> String?
    /// Connects to `host`, port `port`, as `user`, with `key`. `hostKey`
    /// is the computer's key as last seen (nil the first time): a
    /// different one is refused (`PeerSSHError.hostKeyChanged`).
    func connect(user: String, host: String, port: Int, key: Data, hostKey: String?) async throws -> any PeerSSHSession
}

/// One SSH connection to a peer.
@MainActor
public protocol PeerSSHSession: AnyObject {
    /// The computer's host key, as a line to keep and compare next time.
    var hostKey: String { get }
    /// Runs `command` on the peer for each connection to a port here, on
    /// 127.0.0.1: the port, for as long as the connection is open.
    func attach(command: String) async throws -> Int
    func close()
}

/// What SSH to a peer refuses.
public enum PeerSSHError: Error, Equatable, Sendable {
    case unreachable(String)
    case hostKeyChanged
    case keyRefused
}

