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
    /// The credential the provider keeps, apart from the rest, as a secret.
    public var secret: String
    /// Whether this server has answered a sign-in before (the sidebar's
    /// yellow "was reachable" badge rather than red "never").
    public var everConnected: Bool
    /// Which provider reaches it (`AgentServerProviders`).
    public var provider: String
    /// Whether the user gave it its name: then the server's own name,
    /// which a sign-in gives, does not replace it.
    public var renamed: Bool

    public init(id: String = AgentServerRecord.newID(), name: String, address: String, secret: String = "", everConnected: Bool = false,
                provider: String = HTTPAgentServerProvider.name, renamed: Bool = false) {
        self.id = id
        self.name = name
        self.address = address
        self.secret = secret
        self.everConnected = everConnected
        self.provider = provider
        self.renamed = renamed
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
                 "everConnected": .bool(everConnected), "provider": .string(provider), "renamed": .bool(renamed)])
    }

    /// Reads a saved record; one saved by an earlier build, as a computer
    /// with a `host`, `password` and `backend`, reads the same.
    init?(json: JSONValue) {
        guard let id = json["id"].string, let address = json["address"].string ?? json["host"].string else { return nil }
        self.init(id: id, name: json["name"].string ?? "", address: address,
                  secret: json["secret"].string ?? json["password"].string ?? "",
                  everConnected: json["everConnected"].bool ?? false,
                  provider: json["provider"].string ?? json["backend"].string ?? HTTPAgentServerProvider.name,
                  renamed: json["renamed"].bool ?? false)
    }
}
