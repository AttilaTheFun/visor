// Where clients reach this server, as it can tell: the address set by
// hand, else one made from how it listens and what addresses this
// computer has. There is no path of the server's own: a network it is on
// (a LAN, a VPN), a reverse proxy or a tunnel in front
// of it are all the same to it, and the password is what lets a client in.

import Foundation
import VisorProtocol

extension VisorServer {
    public static var settingsURL: URL { storeURL.deletingLastPathComponent().appendingPathComponent("settings.json", isDirectory: false) }

    /// The identity to serve TLS with, read from the file set; nil for
    /// none, or a file that cannot be read (said in `lastError`).
    var tlsIdentity: TLSIdentity? {
        let path = settings.tlsIdentityPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, let data = try? Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) else { return nil }
        return TLSIdentity(pkcs12: data, password: Self.secrets.get("tlsPassword") ?? "")
    }

    /// Whether the server serves TLS itself.
    public var servesTLS: Bool { tlsIdentity != nil }

    /// The TLS identity's password, kept with the secrets; set, the
    /// server listens again with it.
    public func setTLSPassword(_ password: String) {
        Self.secrets.set("tlsPassword", password)
        listenAgain()
    }

    /// The address clients take: the proxy's when one is on, else the
    /// first address of a path that is on — a VPN's before the LAN's,
    /// as it reaches the computer from more places — with the scheme and
    /// the port; nil when only this computer and SSH reach it.
    public var reachableAddress: String? {
        let set = settings.publicAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.proxyEnabled, !set.isEmpty { return set }
        // A code's own address is one other devices reach: never loopback,
        // and none where there is no other (no network: no code).
        let paths = settings.frontPaths.isEmpty ? httpPaths : settings.frontPaths
        return paths.first { !Self.isLoopbackPath($0) }
    }

    /// `http(s)://<address>:<port>` for each address on a path that is
    /// on, the VPN's first; while the LAN is, the computer's name on it
    /// (`<name>.local`), which still reaches it when the network has given
    /// it another address; and this computer's loopback, last, which a
    /// client on this computer tries before any other.
    public var httpPaths: [String] {
        let scheme = servesTLS ? "https" : "http"
        let addresses = ServerPlatform.current.host.networkAddresses()
        let open = addresses.filter { $0.kind == .vpn && settings.vpn } + addresses.filter { $0.kind == .lan && settings.lan }
        var paths = open.map { "\(scheme)://\($0.address):\(port)" }
        if settings.lan, let name = ServerPlatform.current.host.localNetworkName() { paths.append("\(scheme)://\(name):\(port)") }
        paths.append("\(scheme)://127.0.0.1:\(port)")
        return paths
    }

    /// Whether a path leads to this computer's loopback.
    static func isLoopbackPath(_ path: String) -> Bool {
        guard let host = URLComponents(string: path)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    /// `ssh://<user>@<address>` for each of this computer's addresses,
    /// while SSH clients are let in (its sshd listens on them all).
    public var sshPaths: [String] {
        guard settings.sshEnabled else { return [] }
        let user = NSUserName()
        guard !user.isEmpty else { return [] }
        var paths = ServerPlatform.current.host.networkAddresses().map { "ssh://\(user)@\($0.address)" }
        if let name = ServerPlatform.current.host.localNetworkName() { paths.append("ssh://\(user)@\(name)") }
        return paths
    }

    /// Whether a connection that arrived on `localAddress` is let in: this
    /// computer's own always, the socket file always, each network path
    /// as set; an address of no known path is the LAN's.
    func admits(localAddress: String?) -> Bool {
        guard let localAddress, !NetworkAddress.isLoopback(localAddress) else { return true }
        let known = ServerPlatform.current.host.networkAddresses().first { $0.address == localAddress }
        let kind = known?.kind ?? NetworkAddress.kind(of: localAddress, on: "")
        return kind == .vpn ? settings.vpn : settings.lan
    }

    /// Settings changed in a way that changes how the server listens: it
    /// listens again.
    public func listenAgain() {
        guard listening else { return }
        stopListening()
        start()
    }
}
