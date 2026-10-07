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
    /// The server's id on the network of computers, once a sign-in has
    /// said it; "" before, and for a server from before ids.
    public var serverID: String
    /// Other addresses it is reached at, as the server and its peers
    /// say: tried in turn when `address` does not answer.
    public var paths: [String]
    /// The server's own SSH public key line, as its sign-in said it: what
    /// another server is told when this one is introduced, so the two
    /// reach each other over SSH. "" until known.
    public var serverKey: String

    public init(id: String = AgentServerRecord.newID(), name: String, address: String, secret: String = "", everConnected: Bool = false,
                provider: String = VisorAgentServerProvider.name, renamed: Bool = false, serverID: String = "", paths: [String] = [],
                authentication: String = PasswordAuthenticator.name, serverKey: String = "") {
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
        self.serverKey = serverKey
    }

    /// Every address to try, the preferred first, without repeats.
    public var allPaths: [String] {
        var out: [String] = []
        for path in [address] + paths where !path.isEmpty && !out.contains(path) { out.append(path) }
        return out
    }

    /// Takes in addresses the server or its peers say it is reached at.
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

    /// Whether this is the same computer as `peer`: by id when both have
    /// one, else by an address in common.
    public func isSame(as peer: Peer) -> Bool {
        if !serverID.isEmpty, !peer.id.isEmpty { return serverID == peer.id }
        return !Set(allPaths).isDisjoint(with: peer.addresses)
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

    /// This device, as the servers know it: kept, so a server can tell
    /// whose window a terminal is drawn for across launches.
    @MainActor public static let clientID: String = {
        if let saved = VisorHost.settings?.get(key: "clientID"), !saved.isEmpty { return saved }
        let fresh = newID()
        VisorHost.settings?.set(key: "clientID", value: fresh)
        return fresh
    }()

    /// A random id without Foundation's UUID.
    public static func newID() -> String {
        (0..<24).map { _ in String("abcdefghijklmnopqrstuvwxyz0123456789".randomElement()!) }.joined()
    }

    var json: JSONValue {
        .object(["id": .string(id), "name": .string(name), "address": .string(address), "secret": .string(secret),
                 "everConnected": .bool(everConnected), "provider": .string(provider), "renamed": .bool(renamed),
                 "serverID": .string(serverID), "paths": .array(paths.map(JSONValue.string)), "authentication": .string(authentication),
                 "serverKey": .string(serverKey)])
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
                  authentication: json["authentication"].string ?? PasswordAuthenticator.name, serverKey: json["serverKey"].string ?? "")
    }
}
