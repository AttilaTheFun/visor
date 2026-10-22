/// A session's agent run in a container on an oss server rather than on
/// this computer: the server, oss's session for it, and how Visor's tools
/// inside it reach this server. Its adapter starts the agent there
/// (OSSChild), by the agent's name on the container's path, in the
/// session's folder there.
struct ContainerPlacement {
    /// oss's API's address.
    let server: String
    /// oss's session: the container.
    let session: String
    /// Where Visor's MCP script, in the container, reaches this server
    /// (VISOR_URL: ws://host:port).
    let serverURL: String

    /// oss, with its token as kept when asked: one kept after the session
    /// was loaded is the one its agent starts with.
    @MainActor var client: OSSClient { OSSClient(server: server, token: Self.token()) }

    /// oss's token as kept now.
    @MainActor static func token() -> String { VisorServer.secrets.get("ossToken") ?? "" }

    /// Where the server writes Visor's MCP script in the container's home.
    static let scriptPath = "/root/.visor/visor_mcp.js"
}
