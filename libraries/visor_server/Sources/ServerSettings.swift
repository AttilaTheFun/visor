// How the server is reached, as set: its network paths — this computer
// itself (always), the LAN, a VPN, the computer's own SSH, and a reverse
// proxy or tunnel of your own at an address you set — each on or off,
// apart from what a client must show (`authentication`); and TLS. Kept
// in the data directory with the sessions.

import Foundation
import VisorProtocol

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
    /// The paths a front on the computer it runs in reaches it at — that
    /// computer's loopback, its LAN, its VPN (`http://192.168.1.20:7440`)
    /// — for a server in a container, behind Visor Runner: given to clients
    /// in place of the server's own interfaces' addresses, which only that
    /// computer reaches. Empty for a server on a computer of its own.
    public var frontPaths: [String] = []
    /// This server's id on the network of computers: made once, kept.
    public var serverID = ""
    /// What a client must show: "password" (a bearer that is the
    /// password, or a token hello gave), or "none" — anyone who reaches
    /// the server is let in, the path being the proof (a LAN or a VPN of
    /// one's own, SSH alone, a front of your own that signs users in).
    public var authentication = "password"
    /// The server stands alone: reached only at the address each client
    /// added it at (a front it sits behind: an authenticating proxy), its
    /// own addresses, its SSH key and the computers it knows told to no
    /// one, introductions refused. Also on with VISOR_STANDALONE=1.
    public var standalone = false
    /// Let clients keep the sessions' messages on their disk, so a thread
    /// opens as last seen, syncs only what changed and reads back offline.
    /// Off, they keep only the pages they show, in memory, and ask this
    /// server again for any they let go of (`Envelope.keepMessages`).
    public var clientsKeepMessages = true
    /// Each session's agent runs under a host of its own (visor-agent-host),
    /// apart from the server: a restart or an update leaves it working, and
    /// one that runs away cannot take the server down. Off, agents are the
    /// server's own children. On unless turned off; VISOR_DETACH_AGENT_HOST
    /// (0 or 1) overrides it (VisorServer.detachesAgents).
    public var detachAgents = true
    /// The image sessions' containers are made from; empty for Visor's own
    /// (`VisorServer.defaultContainerImage`, this version's).
    public var containerImage = ""
    /// How an agent in a container reaches this server (Visor's tools for
    /// it): a ws:// address; empty for this computer's LAN address, at the
    /// server's port.
    public var containerCallback = ""
    /// The MCP servers passed on to the sessions' agents (MCPProxy): each a
    /// name, an address and headers, a secret one's value kept with the
    /// server's secrets (MCPEndpoint.secretKey).
    public var mcpEndpoints: [MCPEndpoint] = []
    /// The container host sessions' containers come from
    /// (docs/container-host.md): its program and the arguments before each
    /// operation; empty for `visor-container-host` on the PATH, if it is.
    public var containerHost: [String] = []
    /// Where pushes go when this computer has no APNs key of its own: a
    /// proxy that holds the key and signs them (Visor Runner's,
    /// docs/co-tenancy.md), at `<pushProxy>/apns/…`. Empty for none. Its
    /// token for this server is a secret (`VisorServer.pushProxyTokenKey`).
    public var pushProxy = ""

    public init() {}

    enum CodingKeys: String, CodingKey {
        case lan, vpn, reachableFromNetwork, sshEnabled, tlsIdentityPath, proxyEnabled, publicAddress, serverID, authentication, standalone,
             frontPaths, clientsKeepMessages, detachAgents, containerImage, containerCallback, mcpEndpoints, containerHost,
             pushProxy
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
        try c.encode(standalone, forKey: .standalone)
        if !frontPaths.isEmpty { try c.encode(frontPaths, forKey: .frontPaths) }
        try c.encode(clientsKeepMessages, forKey: .clientsKeepMessages)
        try c.encode(detachAgents, forKey: .detachAgents)
        if !containerImage.isEmpty { try c.encode(containerImage, forKey: .containerImage) }
        if !containerCallback.isEmpty { try c.encode(containerCallback, forKey: .containerCallback) }
        if !mcpEndpoints.isEmpty { try c.encode(mcpEndpoints, forKey: .mcpEndpoints) }
        if !containerHost.isEmpty { try c.encode(containerHost, forKey: .containerHost) }
        if !pushProxy.isEmpty { try c.encode(pushProxy, forKey: .pushProxy) }
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
        standalone = try c.decodeIfPresent(Bool.self, forKey: .standalone) ?? false
        frontPaths = try c.decodeIfPresent([String].self, forKey: .frontPaths) ?? []
        clientsKeepMessages = try c.decodeIfPresent(Bool.self, forKey: .clientsKeepMessages) ?? true
        serverID = try c.decodeIfPresent(String.self, forKey: .serverID) ?? ""
        authentication = try c.decodeIfPresent(String.self, forKey: .authentication) ?? "password"
        detachAgents = try c.decodeIfPresent(Bool.self, forKey: .detachAgents) ?? true
        containerImage = try c.decodeIfPresent(String.self, forKey: .containerImage) ?? ""
        containerCallback = try c.decodeIfPresent(String.self, forKey: .containerCallback) ?? ""
        mcpEndpoints = try c.decodeIfPresent([MCPEndpoint].self, forKey: .mcpEndpoints) ?? []
        containerHost = try c.decodeIfPresent([String].self, forKey: .containerHost) ?? []
        pushProxy = try c.decodeIfPresent(String.self, forKey: .pushProxy) ?? ""
    }

    public func keep(at url: URL) {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }

    /// Whether anyone who reaches the server is let in.
    public var asksNothing: Bool { authentication == "none" }
}
