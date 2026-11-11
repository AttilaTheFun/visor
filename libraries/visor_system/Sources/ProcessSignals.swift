/// What the server asks of the system about processes by id: the agents of
/// a previous run it ends, the agents and shells of this one it stops.
public protocol ProcessSignals: Sendable {
    /// Asks a process to end (SIGTERM, or the system's like of it).
    func terminate(_ pid: Int32)
    /// Ends a process, with no choice.
    func kill(_ pid: Int32)
    /// Whether a process with this id is running.
    func isRunning(_ pid: Int32) -> Bool
    /// The command line a process was started with; nil when it cannot be
    /// told.
    func commandLine(of pid: Int32) async -> String?
    /// Writing to a pipe whose reader has gone fails the write, rather than
    /// ending the server.
    func ignoreBrokenPipes()
}
