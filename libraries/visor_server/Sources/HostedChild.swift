// An agent under a host of its own (visor-agent-host, AgentHosting): the
// host is started for it, holds its pipes, and listens on a socket file
// the server talks to it through. When the server goes — a restart, an
// update, a crash — the agent works on, and the next server connects to
// the host again and is sent the lines it had not heard
// (VisorServer+Hosts.swift). Its adapter drives it as it would one on the
// server's own pipes.

import AgentHostWire
import Foundation

@MainActor
final class HostedChild: AgentChild {
    /// The host's socket, which a later server connects to.
    let socket: String
    let output: AsyncStream<Data>
    private let said: AsyncStream<Data>.Continuation
    let errors: AsyncStream<Data>
    private let erred: AsyncStream<Data>.Continuation
    let notices: AsyncStream<String>
    private let noticed: AsyncStream<String>.Continuation
    let exit: Task<AgentExit, Never>
    private let exited: AsyncStream<AgentExit>.Continuation

    /// The agent's process id, once the host has said it; the host's.
    private(set) var pid: Int32 = 0
    private(set) var hostPID: Int32 = 0
    private(set) var isRunning = true
    /// The number of the next line not yet heard: where a later server
    /// picks up.
    private(set) var nextLine: UInt64 = 0
    /// The host no longer had all the lines asked for: more was said
    /// while no server was here than it keeps.
    private(set) var missedLines = false
    /// How much memory the agent and what it runs use, as the host last
    /// said.
    private(set) var memory: UInt64 = 0
    /// Told of each change in the agent's memory.
    var onMemory: ((UInt64) -> Void)?

    private var stream: (any ByteStream)?
    /// What was said before the connection was made.
    private var pending: [Data] = []
    private var reader = AgentHostFrameReader()
    /// Let go of on purpose: the agent works on without this server.
    private var detached = false
    private var greeted: CheckedContinuation<AgentHostHello?, Never>?

    private init(socket: String) {
        self.socket = socket
        (output, said) = AsyncStream.makeStream()
        (errors, erred) = AsyncStream.makeStream()
        (notices, noticed) = AsyncStream.makeStream()
        let (exits, exited) = AsyncStream.makeStream(of: AgentExit.self)
        self.exited = exited
        exit = Task {
            for await exit in exits { return exit }
            return AgentExit(status: -1, signaled: false)
        }
    }

    // MARK: Starting, and picking up again

    /// Starts a host for the agent, which listens at a socket made for it
    /// in `directory`; what is written before it answers waits.
    static func start(executable: String, arguments: [String], directory: String, environment: [String: String],
                      session: String, in folder: URL, memoryLimit: UInt64, hosting: any AgentHosting) throws -> HostedChild {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let child = HostedChild(socket: socketPath(for: session, in: folder))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: hosting.program)
        process.arguments = ["--socket", child.socket, "--directory", directory, "--memory-limit", String(memoryLimit), "--",
                             executable] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let log = folder.appendingPathComponent("hosts.log", isDirectory: false)
        if !FileManager.default.fileExists(atPath: log.path) { _ = FileManager.default.createFile(atPath: log.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: log) {
            _ = handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
        }
        do { try process.run() } catch { throw AgentProcessError.spawnFailed("\(error)") }
        Task {
            // The host listens within moments of starting.
            for _ in 0..<200 {
                if let stream = await hosting.connect(child.socket) {
                    child.begin(stream, from: 0)
                    return
                }
                if !process.isRunning { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            child.erred.yield(Data((AgentChildren.undetachable("its host did not start, or exited before it listened") + "\n").utf8))
            child.ended(AgentExit(status: -1, signaled: false))
        }
        return child
    }

    /// The host left at `socket` by an earlier server, if it still answers
    /// and speaks this server's wire: sent the lines from `line` on.
    static func attach(socket: String, from line: UInt64, hosting: any AgentHosting) async -> HostedChild? {
        guard let stream = await hosting.connect(socket) else { return nil }
        let child = HostedChild(socket: socket)
        child.stream = stream
        stream.receive { [weak child] data in child?.take(data) }
        let hello = await withCheckedContinuation { continuation in
            child.greeted = continuation
            Task {
                try? await Task.sleep(for: .seconds(3))
                child.greet(nil)
            }
        }
        guard let hello, hello.version == AgentHostHello.currentVersion else {
            child.detached = true
            stream.close()
            return nil
        }
        child.nextLine = line
        child.missedLines = hello.oldest > line
        child.send(.attach(from: line))
        return child
    }

    /// A socket's path in `folder`, which must fit the system's limit on
    /// one (104 bytes on a Mac).
    static func socketPath(for session: String, in folder: URL) -> String {
        let tag = String(UUID().uuidString.prefix(6)).lowercased()
        let path = folder.appendingPathComponent("\(session)-\(tag).sock", isDirectory: false).path
        if path.utf8.count < 100 { return path }
        return folder.appendingPathComponent("\(session.prefix(8))-\(tag).sock", isDirectory: false).path
    }

    private func begin(_ stream: any ByteStream, from line: UInt64) {
        guard !detached else {
            stream.close()
            return
        }
        self.stream = stream
        stream.receive { [weak self] data in self?.take(data) }
        stream.send(AgentHostFrame.attach(from: line).encoded, sent: nil)
        for frame in pending { stream.send(frame, sent: nil) }
        pending = []
    }

    // MARK: The agent

    func write(_ object: [String: Any]) {
        guard isRunning, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        send(.input(data + Data([0x0A])))
    }

    func closeInput() {
        if isRunning { send(.closeInput) }
    }

    func end(grace: Duration) async {
        closeInput()
        let force = Task {
            try await Task.sleep(for: grace)
            if isRunning { send(.signal(.terminate)) }
            try await Task.sleep(for: .seconds(1))
            if isRunning { send(.signal(.kill)) }
            // A host that does not answer is ended itself.
            try await Task.sleep(for: .seconds(2))
            if isRunning {
                if hostPID > 0 { ServerPlatform.current.processes.kill(hostPID) }
                ended(AgentExit(status: -1, signaled: true))
            }
        }
        _ = await exit.value
        force.cancel()
    }

    /// Lets the agent go on without this server, which is going: the next
    /// one picks it up.
    func detach() {
        detached = true
        stream?.close()
        stream = nil
    }

    /// The most memory the agent and what it runs may use (0: no limit).
    func limit(_ bytes: UInt64) {
        if isRunning { send(.limit(bytes)) }
    }

    // MARK: The host's side

    private func send(_ frame: AgentHostFrame) {
        if let stream {
            stream.send(frame.encoded, sent: nil)
        } else if !detached {
            pending.append(frame.encoded)
        }
    }

    private func take(_ data: Data?) {
        guard let data else {
            // The host went without saying the agent had: it was ended,
            // and its agent with it.
            if !detached, isRunning {
                erred.yield(Data("The agent's host ended.\n".utf8))
                ended(AgentExit(status: -1, signaled: true))
            }
            greet(nil)
            return
        }
        guard let frames = reader.take(data) else {
            stream?.close()
            return
        }
        for frame in frames { take(frame) }
    }

    private func take(_ frame: AgentHostFrame) {
        switch frame {
        case .hello(let hello):
            pid = hello.agent
            hostPID = hello.host
            greet(hello)
        case .line(let number, let text):
            // A line heard already (sent again to a server that asked
            // from before it) is not passed on twice.
            guard number >= nextLine else { return }
            nextLine = number + 1
            said.yield(text + Data([0x0A]))
        case .errors(let text):
            erred.yield(text)
        case .exited(let status, let signaled):
            ended(AgentExit(status: status, signaled: signaled))
            send(.release)
        case .notice(let text):
            noticed.yield(text)
        case .memory(let bytes):
            memory = bytes
            onMemory?(bytes)
        case .attach, .input, .closeInput, .signal, .limit, .release:
            break
        }
    }

    private func greet(_ hello: AgentHostHello?) {
        greeted?.resume(returning: hello)
        greeted = nil
    }

    private func ended(_ exit: AgentExit) {
        guard isRunning else { return }
        isRunning = false
        said.finish()
        erred.finish()
        noticed.finish()
        exited.yield(exit)
        exited.finish()
    }
}
