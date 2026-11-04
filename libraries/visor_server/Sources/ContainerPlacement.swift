import VisorProtocol

/// A session's agent run in a container rather than on this computer
/// directly: the container, its host, and how Visor's tools inside it reach
/// this server. The session's folder is mounted in the container at its own
/// path, so the agent starts in it there as it would here, by its name on
/// the container's path, under a host of its own like any other agent.
struct ContainerPlacement {
    /// The container, by its host's id for it.
    let id: String
    /// Where Visor's MCP script, in the container, reaches this server
    /// (VISOR_URL: ws://host:port).
    let serverURL: String
    /// How commands are run in it: its container host.
    let exec: any ContainerExecuting
    /// Where Visor's own Linux programs are in it, when they are
    /// (SessionContainer.programs).
    var programs: String? = nil

    /// Where the server's tools for containers (ContainerTools: Visor's MCP
    /// script) are seen in each container.
    static let toolsFolder = "/opt/visor"
    /// Where Visor's image keeps Bazel's output (its /etc/bazel.bazelrc):
    /// the container's disk of its own for builds.
    static let buildOutput = "/var/cache/bazel"
    /// The agent's home: a volume of the container's own, so what the agent
    /// keeps there (its tools' settings and caches, its SSH key) outlasts
    /// the container when it is made again, from another image say. The
    /// agent's log folder is this computer's, mounted inside it.
    static let home = "/root"
    /// How large the home volume is: the same always, as a volume isn't
    /// made larger or smaller (one of another size is made anew, empty).
    static let homeBytes: Int64 = 32 * ContainerSize.gigabyte
    /// Visor's MCP script, in the container.
    static var scriptPath: String { toolsFolder + "/visor_mcp.js" }
    /// Where Visor's own Linux programs are mounted in each container
    /// (HostDetails.containerPrograms), read-only.
    static let programsFolder = "/opt/visor/bin"
}
