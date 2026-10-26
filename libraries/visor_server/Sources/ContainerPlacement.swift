/// A session's agent run in a container on this computer rather than on it
/// directly: the container, and how Visor's tools inside it reach this
/// server. The session's folder is mounted in the container at its own
/// path, so the agent starts in it there as it would here, by its name on
/// the container's path, under a host of its own like any other agent.
struct ContainerPlacement {
    /// The container's lease.
    let name: String
    /// Where commands are run in it on this computer (the lease's socket).
    let socket: String
    /// Where Visor's MCP script, in the container, reaches this server
    /// (VISOR_URL: ws://host:port).
    let serverURL: String
    /// How commands are run in it.
    let exec: any ContainerExecuting

    /// Where the server's tools for containers (ContainerTools: Visor's MCP
    /// script, its `visor` command) are seen in each container.
    static let toolsFolder = "/opt/visor"

    /// Where Visor's image keeps Bazel's output (its /etc/bazel.bazelrc):
    /// the container's disk of its own for builds.
    static let buildOutput = "/var/cache/bazel"

    /// Visor's MCP script, in the container.
    static var scriptPath: String { toolsFolder + "/visor_mcp.js" }
}
