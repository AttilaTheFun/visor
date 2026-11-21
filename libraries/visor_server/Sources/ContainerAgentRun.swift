// A session's agent running in the Sessions container, as the container
// runner holds it: waited on (its end is what the runner acts on) and
// signalled (TERM, then KILL, for one let go that doesn't end by itself).

public protocol ContainerAgentRun: Sendable {
    /// Its status once it has ended (137 when the container went under it).
    func wait() async -> Int32
    /// Sent a signal (15 TERM, 9 KILL); nothing if it has ended.
    func signal(_ number: Int32) async
}
