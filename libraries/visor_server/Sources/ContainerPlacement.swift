/// A session's agent run in a container on this computer rather than on it
/// directly: the container, and how Visor's tools inside it reach this
/// server. The session's folder is mounted in the container at its own
/// path, so the agent starts in it there as it would here, by its name on
/// the container's path, under a host of its own like any other agent.
struct ContainerPlacement {
    /// The container's name.
    let name: String
    /// Where Visor's MCP script, in the container, reaches this server
    /// (VISOR_URL: ws://host:port).
    let serverURL: String
    /// This computer's containers.
    let runtime: any ContainerRunning

    /// Where the server's tools for containers (ContainerTools: Visor's MCP
    /// script, its `visor` command) are seen in each container.
    static let toolsFolder = "/opt/visor"

    /// Visor's MCP script, in the container.
    static var scriptPath: String { toolsFolder + "/visor_mcp.js" }
}
