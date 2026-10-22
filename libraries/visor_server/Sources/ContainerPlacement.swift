import Foundation
import OSSClient

/// A session's agent run in a container on an oss server rather than on
/// this computer: oss (its address, and a client of it), the container,
/// and how Visor's tools inside it reach this server. Its adapter starts
/// the agent there (OSSChild), by the agent's name on the container's
/// path, in the session's folder there.
struct ContainerPlacement {
    /// oss's API's address, as set.
    let server: String
    /// oss, asked with its token as kept when each request is made: one
    /// kept after the session was loaded is the one its agent starts with.
    let client: OSSClient
    /// The container's id on oss.
    let container: String
    /// Where Visor's MCP script, in the container, reaches this server
    /// (VISOR_URL: ws://host:port).
    let serverURL: String

    /// nil for an address that is no URL.
    init?(server: String, container: String, serverURL: String) {
        guard let client = Self.client(server: server) else { return nil }
        self.server = server
        self.client = client
        self.container = container
        self.serverURL = serverURL
    }

    /// A client of the oss at `server` (nil for no URL), through the
    /// platform's HTTP client, with the token as kept at each request.
    static func client(server: String) -> OSSClient? {
        let trimmed = server.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed), url.scheme != nil, url.host != nil else { return nil }
        return OSSClient(server: url, token: { await token() }, transport: PlatformOSSTransport())
    }

    /// oss's token as kept now.
    @MainActor static func token() -> String { VisorServer.secrets.get("ossToken") ?? "" }

    /// Where the server writes Visor's MCP script in the container's home.
    static let scriptPath = "/root/.visor/visor_mcp.js"
}
