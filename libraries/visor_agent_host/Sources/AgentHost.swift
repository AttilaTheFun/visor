// One agent, run apart from the server (visor-agent-host): the host starts
// it on pipes, keeps its latest lines, and listens on a socket of its own
// for the server. The server can restart, update or crash and the agent
// works on; a server that connects again is sent what it missed. The host
// also guards the agent's memory: past its limit, the process holding the
// most is stopped, and the session told.
//
// The host goes once its agent has gone and a server has heard so — or,
// with no server to tell, a while after.

import AgentHostWire
import CVisorPOSIX
import Foundation

@MainActor
public final class AgentHost {
    let options: AgentHostOptions

    /// The agent's process id (0 when it could not be started), and the
    /// end of its input.
    var agent: Int32 = 0
    var input: Outlet?
    /// Its latest lines, and the start of the next one.
    var kept = LineRing(capacity: AgentHost.keptBytes)
    var partial = Data()
    /// How it ended, once it has; and whether its output has been read to
    /// the end (or given up on).
    var ended: (status: Int32, signaled: Bool)?
    var outputDone = false
    /// Whether a server has been told it ended.
    var exitTold = false

    /// The server connected now, which of the connections so far it is,
    /// and whether it has asked for the lines yet.
    var server: Outlet?
    var connection = 0
    var attached = false
    /// When a server was last here: how long the host has been on its own.
    var lastHere = Date()
    /// What no server was here to be told.
    var heldErrors = Data()
    var heldNotices: [String] = []

    /// The memory guard's limit (0: none), the last amount reported, and
    /// the processes it has asked to stop, with when.
    var limit: UInt64
    var lastMemory: UInt64 = 0
    var stopping: [Int32: Date] = [:]

    private var done = false
    private var finished: CheckedContinuation<Void, Never>?

    /// How much of the agent's output is kept for a server that comes back.
    static let keptBytes = 32 << 20
    /// How much of its errors is kept while no server is here.
    static let heldErrorBytes = 1 << 20
    /// How long a host whose agent has gone waits for a server to tell.
    static let linger: TimeInterval = 600
    /// How long an agent runs with no server before it is ended.
    static let abandoned: TimeInterval = 24 * 60 * 60

    init(_ options: AgentHostOptions) {
        self.options = options
        limit = options.memoryLimit
    }

    /// The program: its exit status.
    public static func main(_ arguments: [String]) async -> Int32 {
        let words = Array(arguments.dropFirst())
        if words == ["--version"] {
            print(AgentHostHello.currentVersion)
            return 0
        }
        guard let options = AgentHostOptions(words) else {
            FileHandle.standardError.write(Data("usage: visor-agent-host --socket <path> [--directory <dir>] [--memory-limit <bytes>] -- <agent> <arguments…>\n".utf8))
            return 2
        }
        return await AgentHost(options).run()
    }

    func run() async -> Int32 {
        // A session of its own, so nothing sent to the server's group
        // reaches it.
        _ = setsid()
        visor_ignore_broken_pipes()
        let listener = visor_listen_unix(options.socket)
        guard listener >= 0 else {
            log("cannot listen at \(options.socket): \(String(cString: strerror(errno)))")
            return 1
        }
        start()
        Task { for await connection in connections(to: listener) { self.connect(connection) } }
        Task { await self.watch() }
        if !done { await withCheckedContinuation { finished = $0 } }
        unlink(options.socket)
        close(listener)
        return 0
    }

    /// Every few seconds: the memory guard, and whether the host has been
    /// on its own too long.
    private func watch() async {
        while !done {
            try? await Task.sleep(for: .seconds(5))
            guardMemory()
            let away = Date().timeIntervalSince(lastHere)
            guard server == nil else { continue }
            if ended != nil, outputDone, away > Self.linger {
                finish()
            } else if ended == nil, away > Self.abandoned {
                log("no server for a day: ending the agent")
                input?.close()
                input = nil
                if agent > 0 { kill(agent, SIGTERM) }
                lastHere = Date()
            }
        }
    }

    func finish() {
        guard !done else { return }
        done = true
        input?.close()
        server?.shutdown()
        finished?.resume()
        finished = nil
    }

    func log(_ line: String) {
        FileHandle.standardError.write(Data("\(Date()) [\(options.socket)] \(line)\n".utf8))
    }
}
