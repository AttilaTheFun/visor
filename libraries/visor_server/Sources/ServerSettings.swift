// How the server is reached, as set: whether the network may reach it
// over HTTP (with the password) or only this computer (a front of your
// own then), whether SSH-authenticated users reach it (no password), TLS,
// and the address clients are told. Kept in the data directory with the
// sessions.

import Foundation

public struct ServerSettings: Codable, Equatable, Sendable {
    /// Listen on every interface, for the network to reach the server
    /// directly: a LAN, a VPN, a tunnel. Off, only this
    /// computer reaches it, and a reverse proxy or a tunnel here is the
    /// road in.
    public var reachableFromNetwork = false
    /// Also listen on a socket file only this user can open
    /// (`VisorServer.socketPath`): a client that comes through the
    /// computer's own SSH as this user reaches it there, already
    /// authenticated, and needs no password. Off, SSH clients reach the
    /// port on loopback instead, with the password.
    public var sshEnabled = true
    /// A PKCS#12 file with the certificate and key to serve TLS with;
    /// empty for plain TCP (TLS being the front's, or the road trusted).
    /// Its password is a secret (`tlsPassword`).
    public var tlsIdentityPath = ""
    /// What clients are told to reach the server at, set by hand: the
    /// URL a proxy, a tunnel or a name on the network gives. Empty: the
    /// server's own guess from its addresses.
    public var publicAddress = ""

    public init() {}

    public static func kept(at url: URL) -> ServerSettings {
        guard let data = try? Data(contentsOf: url), let settings = try? JSONDecoder().decode(ServerSettings.self, from: data) else { return ServerSettings() }
        return settings
    }

    // Decoded field by field: a file from before a field reads as the
    // default, not as unreadable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reachableFromNetwork = try c.decodeIfPresent(Bool.self, forKey: .reachableFromNetwork) ?? false
        sshEnabled = try c.decodeIfPresent(Bool.self, forKey: .sshEnabled) ?? true
        tlsIdentityPath = try c.decodeIfPresent(String.self, forKey: .tlsIdentityPath) ?? ""
        publicAddress = try c.decodeIfPresent(String.self, forKey: .publicAddress) ?? ""
    }

    public func keep(at url: URL) {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }
}
