/// What a host says of itself when a server connects.
public struct AgentHostHello: Codable, Equatable, Sendable {
    /// The wire's version: a server connects only to a host whose version
    /// it speaks.
    public var version: Int
    /// The host's process id, and its agent's.
    public var host: Int32
    public var agent: Int32
    /// The first line the host still has, and the number the next line
    /// will have: a server that last heard a line before `oldest` has
    /// missed some.
    public var oldest: UInt64
    public var next: UInt64
    /// How the agent ended, when it has.
    public var status: Int32?
    public var signaled: Bool?

    public static let currentVersion = 1

    public init(version: Int = Self.currentVersion, host: Int32, agent: Int32, oldest: UInt64, next: UInt64,
                status: Int32? = nil, signaled: Bool? = nil) {
        self.version = version
        self.host = host
        self.agent = agent
        self.oldest = oldest
        self.next = next
        self.status = status
        self.signaled = signaled
    }
}
