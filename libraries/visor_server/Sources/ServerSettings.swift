// How the server is reached, as set: its network paths — this computer
// itself (always), the LAN, a VPN, the computer's own SSH, and a reverse
// proxy or tunnel of your own at an address you set — each on or off,
// apart from what a client must show (`authentication`); and TLS. Kept
// in the data directory with the sessions.

import Foundation

public struct ServerSettings: Codable, Equatable, Sendable {
    /// Let the LAN reach the port: the home or office network this
    /// computer is on.
    public var lan = false
    /// Let a VPN reach the port: a tailnet, a company's VPN (the
    /// interfaces such networks make; `NetworkAddress.Kind`).
    public var vpn = false
    /// Whether the network reaches the port at all: the listener is on
    /// every interface then, and each connection is let in or not by the
    /// path it came on.
    public var reachableFromNetwork: Bool { lan || vpn }
    /// Also listen on a socket file only this user can open
    /// (`VisorServer.socketPath`): a client that comes through the
    /// computer's own SSH as this user reaches it there, already
    /// authenticated, and needs no password. Off, SSH clients reach the
    /// port on loopback instead, with the password.
    public var sshEnabled = true
    /// A PKCS#12 file with the certificate and key to serve TLS with;
    /// empty for plain TCP (TLS being the front's, or the path trusted).
    /// Its password is a secret (`tlsPassword`).
    public var tlsIdentityPath = ""
    /// A reverse proxy or a tunnel of your own in front of the server
    /// (on this computer, or wherever its address leads): on, clients are
    /// told `publicAddress`, the URL it gives, first.
    public var proxyEnabled = false
    /// The proxy's or tunnel's URL (`https://proxy.example.com/visor`), or
    /// a name on the network with certificates (HTTPS at the root).
    public var publicAddress = ""
    /// This server's id on the network of computers: made once, kept.
    public var serverID = ""
    /// What a client must show: "password" (a bearer that is the
    /// password, or a token hello gave), or "none" — anyone who reaches
    /// the server is let in, the path being the proof (a LAN or a VPN of
    /// one's own, SSH alone, a front of your own that signs users in).
    public var authentication = "password"

    public init() {}

    enum CodingKeys: String, CodingKey {
        case lan, vpn, reachableFromNetwork, sshEnabled, tlsIdentityPath, proxyEnabled, publicAddress, serverID, authentication
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(lan, forKey: .lan)
        try c.encode(vpn, forKey: .vpn)
        try c.encode(sshEnabled, forKey: .sshEnabled)
        try c.encode(tlsIdentityPath, forKey: .tlsIdentityPath)
        try c.encode(proxyEnabled, forKey: .proxyEnabled)
        try c.encode(publicAddress, forKey: .publicAddress)
        try c.encode(serverID, forKey: .serverID)
        try c.encode(authentication, forKey: .authentication)
    }

    public static func kept(at url: URL) -> ServerSettings {
        guard let data = try? Data(contentsOf: url), let settings = try? JSONDecoder().decode(ServerSettings.self, from: data) else { return ServerSettings() }
        return settings
    }

    // Decoded field by field: a file from before a field reads as the
    // default, not as unreadable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A file from before the paths: "reachable from the network" was
        // the LAN and a VPN both; an address set was a proxy in use.
        let network = try c.decodeIfPresent(Bool.self, forKey: .reachableFromNetwork) ?? false
        lan = try c.decodeIfPresent(Bool.self, forKey: .lan) ?? network
        vpn = try c.decodeIfPresent(Bool.self, forKey: .vpn) ?? network
        sshEnabled = try c.decodeIfPresent(Bool.self, forKey: .sshEnabled) ?? true
        tlsIdentityPath = try c.decodeIfPresent(String.self, forKey: .tlsIdentityPath) ?? ""
        publicAddress = try c.decodeIfPresent(String.self, forKey: .publicAddress) ?? ""
        proxyEnabled = try c.decodeIfPresent(Bool.self, forKey: .proxyEnabled) ?? !publicAddress.isEmpty
        serverID = try c.decodeIfPresent(String.self, forKey: .serverID) ?? ""
        authentication = try c.decodeIfPresent(String.self, forKey: .authentication) ?? "password"
    }

    public func keep(at url: URL) {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }

    /// Whether anyone who reaches the server is let in.
    public var asksNothing: Bool { authentication == "none" }
}
