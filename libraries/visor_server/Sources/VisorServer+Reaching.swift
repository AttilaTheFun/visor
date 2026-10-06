// Where clients reach this server, as it can tell: the address set by
// hand, else one made from how it listens and what addresses this
// computer has. There is no road of the server's own: a network it is on
// (a LAN, a VPN), a reverse proxy or a tunnel in front
// of it are all the same to it, and the password is what lets a client in.

import Foundation
import VisorProtocol

extension VisorServer {
    public static var settingsURL: URL { storeURL.deletingLastPathComponent().appendingPathComponent("settings.json") }

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

    /// The address clients take: the one set by hand, else — when the
    /// network reaches the server — its first address, with the scheme
    /// and the port; nil when only this computer reaches it and nothing
    /// was set (a front of your own, whose address is yours to set).
    public var reachableAddress: String? {
        let set = settings.publicAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !set.isEmpty { return set }
        guard settings.reachableFromNetwork, let first = ServerPlatform.current.host.addresses().first else { return nil }
        return "\(servesTLS ? "https" : "http")://\(first):\(port)"
    }

    /// Settings changed in a way that changes how the server listens: it
    /// listens again.
    public func listenAgain() {
        guard listening else { return }
        stopListening()
        start()
    }
}
