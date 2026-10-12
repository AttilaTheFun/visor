/// Where agents run apart from the server, so it can restart (or crash)
/// and they work on: each under a host of its own (visor-agent-host),
/// started by the server and listening on a socket file the server
/// connects to again after a restart. Nil in `ServerPlatform` where the
/// system has no host (Windows).
public protocol AgentHosting: Sendable {
    /// The host program.
    var program: String { get }
    /// Why the host cannot be started here (the program is not there, or
    /// does not run); nil when it can.
    func problem() -> String?
    /// A connection to the socket at `path`; nil when nothing listens
    /// there.
    @MainActor func connect(_ path: String) async -> (any ByteStream)?
}
