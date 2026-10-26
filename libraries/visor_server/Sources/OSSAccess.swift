import Foundation
import OSSClient

/// The oss servers (OS Server, AttilaTheFun/oss) this server's sessions
/// lease from — machines (macOS, Linux and Windows VMs, iOS simulators,
/// Android emulators) from the nearest with room, containers from the one
/// on this computer — through this server, which holds their tokens.
@MainActor
enum OSSAccess {
    /// How oss is reached: the platform's HTTP client (a fake in tests).
    static var transport: any OSSTransport = PlatformOSSTransport()

    /// A server's address as kept: without a trailing slash.
    nonisolated static func normalized(_ server: String) -> String {
        let trimmed = server.trimmingCharacters(in: .whitespaces)
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    /// An address that is a URL (a scheme and a host).
    nonisolated static func url(_ server: String) -> URL? {
        guard let url = URL(string: normalized(server)), url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    /// A client of the oss at `server` (nil for no URL), through the
    /// platform's HTTP client, with its token as kept at each request.
    static func client(server: String) -> OSSClient? {
        guard let url = url(server) else { return nil }
        let key = tokenKey(server)
        return OSSClient(server: url, token: { await token(key) }, transport: transport)
    }

    /// The servers, as leased from: each by its host's name, its token as
    /// kept at each request.
    static func pool(servers: [String]) -> OSSPool {
        let entries = servers.compactMap { server -> OSSServerEntry? in
            guard let url = url(server) else { return nil }
            let key = tokenKey(server)
            return OSSServerEntry(name: url.host ?? server, servers: [url], token: { await token(key) })
        }
        return OSSPool(entries: entries, transport: transport)
    }

    /// Where a server's token is kept with the server's secrets.
    nonisolated static func tokenKey(_ server: String) -> String { "ossToken " + normalized(server) }

    /// A server's token as kept now.
    static func token(_ key: String) -> String { VisorServer.secrets.get(key) ?? "" }

    /// The token kept from before several servers ("ossToken", the one
    /// server's) taken over as `server`'s.
    static func adoptSingleToken(for server: String) {
        guard let token = VisorServer.secrets.get("ossToken"), !token.isEmpty else { return }
        if (VisorServer.secrets.get(tokenKey(server)) ?? "").isEmpty { VisorServer.secrets.set(tokenKey(server), token) }
        VisorServer.secrets.set("ossToken", nil)
    }
}
