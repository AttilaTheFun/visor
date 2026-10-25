/// What a Visor server's computer is using and for whom (`GET
/// /api/resources`): its processors and memory, its sessions' containers,
/// and the machines its sessions lease from oss, with oss's computer.
public struct ServerResources: Codable, Hashable, Sendable {
    /// When it was read: seconds since 1970.
    public var sampledAt: Double
    /// The server's own computer.
    public var host: ComputerUsage?
    public var containers: [ContainerUsage]
    public var machines: [LeaseUsage]
    /// The computer oss runs the machines on, where it says.
    public var machinesHost: ComputerUsage?
    /// Why the machines' numbers are missing, where they are (no oss set,
    /// or one that does not say).
    public var machinesNote: String?

    public init(sampledAt: Double, host: ComputerUsage? = nil, containers: [ContainerUsage] = [], machines: [LeaseUsage] = [],
                machinesHost: ComputerUsage? = nil, machinesNote: String? = nil) {
        self.sampledAt = sampledAt
        self.host = host
        self.containers = containers
        self.machines = machines
        self.machinesHost = machinesHost
        self.machinesNote = machinesNote
    }
}
