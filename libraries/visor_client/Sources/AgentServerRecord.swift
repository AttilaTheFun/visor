import SwiftUI
import MessageCache
import VisorProtocol
import VisorServices

/// A saved agent server: which provider reaches it, where, and with what
/// credentials. The provider reads `address` and `secret` as its own —
/// for a Visor server, where it is reached (`ServerAddress`) and its
/// password; for a fork's service, whatever its sign-in leaves behind.
public struct AgentServerRecord: Identifiable, Hashable, Sendable {
    public var id: String
    /// What the sidebar calls it (the server's own name once known).
    public var name: String
    /// Where the provider finds it.
    public var address: String
    /// The credential the provider keeps, apart from the rest, as a secret:
    /// what the authenticator makes the headers from.
    public var secret: String
    /// How the client proves itself (`AgentServerAuthenticators`): the
    /// password unless said otherwise.
    public var authentication: String
    /// Whether this server has answered a sign-in before (the sidebar's
    /// yellow "was reachable" badge rather than red "never").
    public var everConnected: Bool
    /// Which provider reaches it (`AgentServerProviders`).
    public var provider: String
    /// Whether the user gave it its name: then the server's own name,
    /// which a sign-in gives, does not replace it.
    public var renamed: Bool
    /// The server's own id, once a sign-in has said it; "" before, and for
    /// a server from before ids.
    public var serverID: String
    /// Other addresses it is reached at, as the server says: tried in
    /// turn when `address` does not answer.
    public var paths: [String]
    /// The path the last sign-in answered on ("" for none yet): tried
    /// first among those that fit as well, so a launch starts where the
    /// last one got in.
    public var lastPath: String
    /// The server said it stands alone: reached only at `address`, its
    /// other paths not learned or tried, and kept out of the relay.
    public var standalone: Bool
    /// Whether this device takes part in the relay with this server
    /// (RelayCourier): tells it the other computers it is connected to and
    /// their sessions, and carries its agents' messages to them. Nil: as
    /// the app's default (`RelayCourier.onByDefault`).
    public var relay: Bool?
    /// One of the app's account's servers (`VisorAccount`): added when it
    /// signs in, gone when it signs out, not added or forgotten by hand.
    public var fromAccount: Bool

    public init(id: String = AgentServerRecord.newID(), name: String, address: String, secret: String = "", everConnected: Bool = false,
                provider: String = VisorAgentServerProvider.name, renamed: Bool = false, serverID: String = "", paths: [String] = [],
                authentication: String = PasswordAuthenticator.name, standalone: Bool = false, relay: Bool? = nil,
                fromAccount: Bool = false, lastPath: String = "") {
        self.standalone = standalone
        self.relay = relay
        self.fromAccount = fromAccount
        self.id = id
        self.name = name
        self.address = address
        self.secret = secret
        self.authentication = authentication
        self.everConnected = everConnected
        self.provider = provider
        self.renamed = renamed
        self.serverID = serverID
        self.paths = paths
        self.lastPath = lastPath
    }

    /// Every address to try, the preferred first, without repeats.
    public var allPaths: [String] {
        var out: [String] = []
        for path in [address] + paths where !path.isEmpty && !out.contains(path) { out.append(path) }
        return out
    }

    /// Lets go of a path found to reach another computer.
    public mutating func forgetPath(_ path: String) {
        paths.removeAll { $0 == path }
    }

    /// Takes in addresses the server says it is reached at.
    /// Whether any was new.
    @discardableResult
    public mutating func learnPaths(_ addresses: [String]) -> Bool {
        var learned = false
        for path in addresses where !path.isEmpty && path != address && !paths.contains(path) {
            paths.append(path)
            learned = true
        }
        return learned
    }

    /// The addresses the server gave at a sign-in, as its paths now, in
    /// its order. One it no longer gives goes if it is at an interface's
    /// address — an IP, which a lease that moved, a link-local address or
    /// a bridge to a virtual machine leaves behind, and which would only
    /// be tried and waited out — and stays after the server's own if it
    /// is a name (a proxy, a tunnel it does not know of), as does the one
    /// the last sign-in answered on (a port forwarded to it). Whether
    /// they changed.
    @MainActor @discardableResult
    public mutating func takePaths(_ addresses: [String]) -> Bool {
        guard !addresses.isEmpty else { return false }
        var next: [String] = []
        for path in addresses where !path.isEmpty && path != address && !next.contains(path) { next.append(path) }
        for path in paths where path != address && !next.contains(path) {
            if path != lastPath, let host = AgentServerConnection.host(ofPath: path), Self.isIP(host) { continue }
            next.append(path)
        }
        guard next != paths else { return false }
        paths = next
        return true
    }

    /// An IPv4 or IPv6 address rather than a name.
    static func isIP(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    /// The server's own name, as a sign-in gives it: taken unless the
    /// user named the server themselves.
    public mutating func takeServerName(_ name: String) {
        guard !name.isEmpty, !renamed, name != self.name else { return }
        self.name = name
    }

    /// Names the server as the user typed it; an empty name follows the
    /// server's own again.
    public mutating func rename(to name: String) {
        var trimmed = Substring(name)
        while let first = trimmed.first, first.isWhitespace || first.isNewline { trimmed = trimmed.dropFirst() }
        while let last = trimmed.last, last.isWhitespace || last.isNewline { trimmed = trimmed.dropLast() }
        guard trimmed != self.name || (trimmed.isEmpty && renamed) else { return }
        self.name = String(trimmed)
        renamed = !trimmed.isEmpty
    }

    /// This device, as the servers know it: kept (with the secrets, so a
    /// reinstall keeps it too), so a server knows this device's reports
    /// across launches.
    @MainActor public static let clientID: String = {
        if let saved = VisorHost.settings?.kept(key: "clientID"), !saved.isEmpty { return saved }
        let fresh = newID()
        VisorHost.settings?.setKept(key: "clientID", value: fresh)
        return fresh
    }()

    /// A random id without Foundation's UUID.
    public static func newID() -> String {
        (0..<24).map { _ in String("abcdefghijklmnopqrstuvwxyz0123456789".randomElement()!) }.joined()
    }

    var json: JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(id), "name": .string(name), "address": .string(address), "secret": .string(secret),
            "everConnected": .bool(everConnected), "provider": .string(provider), "renamed": .bool(renamed),
            "serverID": .string(serverID), "paths": .array(paths.map(JSONValue.string)), "authentication": .string(authentication),
            "standalone": .bool(standalone), "fromAccount": .bool(fromAccount), "lastPath": .string(lastPath)]
        if let relay { fields["relay"] = .bool(relay) }
        return .object(fields)
    }

    /// Reads a saved record; one saved by an earlier build, as a computer
    /// with a `host`, `password` and `backend`, reads the same.
    init?(json: JSONValue) {
        guard let id = json["id"].string, let address = json["address"].string ?? json["host"].string else { return nil }
        self.init(id: id, name: json["name"].string ?? "", address: address,
                  secret: json["secret"].string ?? json["password"].string ?? "",
                  everConnected: json["everConnected"].bool ?? false,
                  provider: json["provider"].string ?? json["backend"].string ?? VisorAgentServerProvider.name,
                  renamed: json["renamed"].bool ?? false, serverID: json["serverID"].string ?? "",
                  paths: (json["paths"].array ?? json["roads"].array)?.compactMap(\.string) ?? [],
                  authentication: json["authentication"].string ?? PasswordAuthenticator.name,
                  standalone: json["standalone"].bool ?? false, relay: json["relay"].bool, fromAccount: json["fromAccount"].bool ?? false,
                  lastPath: json["lastPath"].string ?? "")
    }
}
