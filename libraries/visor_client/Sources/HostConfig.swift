import SwiftUI
import MessageCache
import VisorProtocol
import VisorServices

public struct HostConfig: Identifiable, Hashable, Sendable {
    public var id: String
    /// What the sidebar calls it (the host name once known).
    public var name: String
    /// The Mac's Tailscale name (its Serve endpoint): always wss:// on 443.
    public var host: String
    public var password: String
    /// Whether this computer has answered a login before (the sidebar's
    /// yellow "was reachable" badge rather than red "never").
    public var everConnected: Bool
    /// Which road reaches it (`Backends`); "tailscale" unless a fork says.
    public var backend: String

    public init(id: String = HostConfig.newID(), name: String, host: String, password: String, everConnected: Bool = false,
                backend: String = "tailscale") {
        self.id = id
        self.name = name
        self.host = host
        self.password = password
        self.everConnected = everConnected
        self.backend = backend
    }

    /// A random id without Foundation's UUID.
    /// This device, as the computers know it: kept, so a computer can
    /// tell whose window a terminal is drawn for across launches.
    @MainActor public static let clientID: String = {
        if let saved = VisorHost.settings?.get(key: "clientID"), !saved.isEmpty { return saved }
        let fresh = newID()
        VisorHost.settings?.set(key: "clientID", value: fresh)
        return fresh
    }()

    public static func newID() -> String {
        (0..<24).map { _ in String("abcdefghijklmnopqrstuvwxyz0123456789".randomElement()!) }.joined()
    }

    var json: JSONValue {
        .object(["id": .string(id), "name": .string(name), "host": .string(host), "password": .string(password),
                 "everConnected": .bool(everConnected), "backend": .string(backend)])
    }

    init?(json: JSONValue) {
        guard let id = json["id"].string, let host = json["host"].string else { return nil }
        self.init(id: id, name: json["name"].string ?? "", host: host, password: json["password"].string ?? "",
                  everConnected: json["everConnected"].bool ?? false, backend: json["backend"].string ?? "tailscale")
    }
}
