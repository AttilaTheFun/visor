// What the server's settings say of the Sessions container, resolved for
// this Mac (ContainerSettings and agent-proxy's relay port): read by the
// engine each time it needs them, so a change takes effect at its next
// start (and turning it off stops it).

public struct ContainerEngineConfiguration: Equatable, Sendable {
    public var enabled: Bool
    public var cpus: Int
    public var memoryGiB: Int
    public var idleMinutes: Int
    /// The agent image: the release's or Settings'; nil when neither pins one.
    public var image: ImageDigest?
    /// agent-proxy's relay listener on loopback: the container's way out.
    public var relayPort: Int?
    /// A host folder for the checkouts, shared at the same path; nil: none.
    public var checkouts: String?
    /// agent-proxy's MCP pass-through's servers, for its Claude (written at
    /// each boot); nil: its Claude's file isn't touched.
    public var claudeMCP: ContainerClaudeMCP?

    public init(enabled: Bool, cpus: Int, memoryGiB: Int, idleMinutes: Int, image: ImageDigest?, relayPort: Int?, checkouts: String? = nil,
                claudeMCP: ContainerClaudeMCP? = nil) {
        self.enabled = enabled
        self.cpus = cpus
        self.memoryGiB = memoryGiB
        self.idleMinutes = idleMinutes
        self.image = image
        self.relayPort = relayPort
        self.checkouts = checkouts
        self.claudeMCP = claudeMCP
    }
}
