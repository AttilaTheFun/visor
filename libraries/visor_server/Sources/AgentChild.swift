import Foundation

/// A running agent as its adapter (ClaudeProcess, CodexAppServerProcess)
/// drives it: JSON lines in, its output and errors out, and how it ended.
/// On the server's own pipes (PipedChild), or under a host of its own that
/// outlives the server (HostedChild).
@MainActor
protocol AgentChild: AnyObject {
    var output: AsyncStream<Data> { get }
    var errors: AsyncStream<Data> { get }
    /// What was done to the agent that its session is told (the host's
    /// memory guard).
    var notices: AsyncStream<String> { get }
    /// How it ended, once it has.
    var exit: Task<AgentExit, Never> { get }
    var pid: Int32 { get }
    var isRunning: Bool { get }
    /// One JSON object as a line on its standard input.
    func write(_ object: [String: Any])
    /// End of input: an agent reading its standard input finishes what it
    /// is doing and exits.
    func closeInput()
    /// Ends it and returns when it is gone: end of input first, then,
    /// `grace` later, a request to terminate, and a second after that no
    /// choice.
    func end(grace: Duration) async
}
