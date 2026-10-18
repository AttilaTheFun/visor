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
    /// Each session's agent runs under a host of its own (visor-agent-host),
    /// apart from the server: a restart or an update leaves it working, and
    /// one that runs away cannot take the server down. Off, agents are the
    /// server's own children. On unless turned off; VISOR_DETACH_AGENT_HOST
    /// (0 or 1) overrides it (VisorServer.detachesAgents).
    public var detachAgents = true
    /// The most virtual machines of each platform (`MachinePlatform`'s raw
    /// value) the server may run agents' sessions in at once; none by
    /// default, a platform not named being 0.
    public var machines: [String: Int] = [:]
    /// The script that provisions a virtual machine and wraps it and the
    /// agent inside it (its contract: docs/DEVELOPMENT.md, Virtual
    /// machines), for a host to bring its own images, network and tools;
    /// empty for Visor's own.
    public var provisioningScript = ""

    public init() {}

    /// The most machines of the platform the server may run at once.
    public func maxMachines(_ platform: MachinePlatform) -> Int { max(0, machines[platform.rawValue] ?? 0) }

    /// Sets it, within what the system allows (Apple's two macOS machines
    /// per Mac); 0 takes the platform off.
    public mutating func setMaxMachines(_ platform: MachinePlatform, _ count: Int) {
        let allowed = min(max(0, count), platform.hostLimit ?? Int.max)
        machines[platform.rawValue] = allowed == 0 ? nil : allowed
    }

    enum CodingKeys: String, CodingKey {
        case lan, vpn, reachableFromNetwork, sshEnabled, tlsIdentityPath, proxyEnabled, publicAddress, serverID, authentication, standalone,
             detachAgents, machines, provisioningScript
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
        try c.encode(detachAgents, forKey: .detachAgents)
        if !machines.isEmpty { try c.encode(machines, forKey: .machines) }
        if !provisioningScript.isEmpty { try c.encode(provisioningScript, forKey: .provisioningScript) }
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
        serverID = try c.decodeIfPresent(String.self, forKey: .serverID) ?? ""
        authentication = try c.decodeIfPresent(String.self, forKey: .authentication) ?? "password"
        detachAgents = try c.decodeIfPresent(Bool.self, forKey: .detachAgents) ?? true
        machines = try c.decodeIfPresent([String: Int].self, forKey: .machines) ?? [:]
        provisioningScript = try c.decodeIfPresent(String.self, forKey: .provisioningScript) ?? ""
    }

    public func keep(at url: URL) {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }

    /// Whether anyone who reaches the server is let in.
    public var asksNothing: Bool { authentication == "none" }
}
