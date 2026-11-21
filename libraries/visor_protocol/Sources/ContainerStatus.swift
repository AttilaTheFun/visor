// The Sessions container as `GET /api/container` (an admin's) answers, and
// `POST /api/container/start` and `/stop` after what they did
// (docs/containers.md): its state, its resources, the image it runs (or
// would), how its egress check went, and what went wrong lately. The
// container engine (libraries/visor_container) makes it; Settings shows it.

public struct ContainerStatus: Equatable, Sendable {
    public var state: ContainerState
    /// The setting (ContainerSettings.enabled).
    public var enabled: Bool
    /// Whether this server can run it: a Mac with macOS 26 or later, Apple
    /// silicon and virtualization, in Visor's background server.
    public var canRun: Bool
    /// Its CPUs and memory: the running container's, else what it would
    /// start with now.
    public var cpus: Int?
    public var memoryGiB: Int?
    /// Minutes with nothing in it before it's stopped.
    public var idleMinutes: Int?
    /// The agent image's digest (`sha256:…`): the running container's, else
    /// the one pinned; nil when none is.
    public var image: String?
    /// When the state began, in seconds since 1970.
    public var since: Double?
    /// The processes run in it now (exec'd: the sessions' wrappers, later).
    public var processes: Int
    /// agent-proxy's relay port, its way out; nil when none is set.
    public var relayPort: Int?
    /// What the egress check (`relay-client check`) said last.
    public var egress: String?
    /// What went wrong lately, the latest last (at most a few).
    public var errors: [String]
    /// Why it's held stopped, when it was stopped on purpose (Stop, or
    /// turned off): its sessions' agents wait for Start Agent then, rather
    /// than starting it again. Nil while it runs, and after a stop it
    /// takes up again by itself (a crash, an idle stop, a restart).
    public var held: String?

    public init(state: ContainerState, enabled: Bool = false, canRun: Bool = false, cpus: Int? = nil, memoryGiB: Int? = nil,
                idleMinutes: Int? = nil, image: String? = nil, since: Double? = nil, processes: Int = 0, relayPort: Int? = nil,
                egress: String? = nil, errors: [String] = [], held: String? = nil) {
        self.state = state
        self.enabled = enabled
        self.canRun = canRun
        self.cpus = cpus
        self.memoryGiB = memoryGiB
        self.idleMinutes = idleMinutes
        self.image = image
        self.since = since
        self.processes = processes
        self.relayPort = relayPort
        self.egress = egress
        self.errors = errors
        self.held = held
    }

    /// Whether a session may be started in it now, or would start it: on
    /// and runnable, and not refused for its egress.
    public var takesSessions: Bool { enabled && canRun && state != .off && state != .noEgress }
}
