// An agent under a host of its own (visor-agent-host, AgentHosting): the
// host is started for it, holds its pipes, and listens on a socket file
// the server talks to it through. When the server goes — a restart, an
// update, a crash — the agent works on, and the next server connects to
// the host again and is sent the lines it had not heard
// (VisorServer+Hosts.swift). Its adapter drives it as it would one on the
// server's own pipes.

import AgentHostWire
import Foundation
import VisorSystem

@MainActor
package final class HostedChild: AgentChild {
    /// The host's socket, which a later server connects to.
    package let socket: String
    package let output: AsyncStream<Data>
    private let said: AsyncStream<Data>.Continuation
    package let errors: AsyncStream<Data>
    private let erred: AsyncStream<Data>.Continuation
    package let notices: AsyncStream<String>
    private let noticed: AsyncStream<String>.Continuation
    package let exit: Task<AgentExit, Never>
    private let exited: AsyncStream<AgentExit>.Continuation

    /// The agent's process id, once the host has said it; the host's.
    package private(set) var pid: Int32 = 0
    private(set) var hostPID: Int32 = 0
    package private(set) var isRunning = true
    /// The number of the next line not yet heard: where a later server
    /// picks up.
    package private(set) var nextLine: UInt64 = 0
    /// The host no longer had all the lines asked for: more was said
    /// while no server was here than it keeps.
    package private(set) var missedLines = false
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
    /// in `sockets` (beside the hosts' log in `folder` unless told
    /// otherwise; with `shortNames`, `h-<8 hex>.sock`, as the app group's
    /// container's are), started by `spawner`; what is written before it
    /// answers waits. `harness` is the agent's kind, for the spawner.
    static func start(executable: String, arguments: [String], directory: String, environment: [String: String],
                      session: String, harness: String = "", in folder: URL, socketsIn sockets: URL? = nil, shortNames: Bool = false,
                      memoryLimit: UInt64, hosting: any AgentHosting,
                      spawner: any AgentHostSpawner = ProcessAgentHostSpawner()) throws -> HostedChild {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sockets = sockets ?? folder
        try? FileManager.default.createDirectory(at: sockets, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let socket = shortNames ? shortSocketPath(in: sockets) : socketPath(for: session, in: sockets)
        // The app group's container's names are short so that each fits.
        guard !shortNames || socket.utf8.count < socketPathLimit else {
            throw AgentProcessError.spawnFailed("the host's socket's path, \(socket), is longer than a socket's may be (\(socketPathLimit - 1) bytes)")
        }
        let child = HostedChild(socket: socket)
        let request = AgentHostSpawnRequest(session: session, folder: directory,
                                            harness: harness.isEmpty ? URL(fileURLWithPath: executable).lastPathComponent : harness,
                                            executable: executable, arguments: arguments, environment: environment, socket: socket,
                                            memoryLimit: memoryLimit, log: folder.appendingPathComponent("hosts.log", isDirectory: false).path)
        let process = try spawner.spawn(request, program: hosting.program)
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
    package static func attach(socket: String, from line: UInt64, hosting: any AgentHosting) async -> HostedChild? {
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

    /// The most bytes a socket's path may have on a Mac, its closing NUL
    /// among them (`sun_path`).
    static let socketPathLimit = 104

    /// A short socket's path in `folder`: `h-<8 hex>.sock`, one no other
    /// socket there has (VisorPlaces' names, in the app group's container).
    static func shortSocketPath(in folder: URL) -> String {
        var path = ""
        for _ in 0..<16 {
            let hex = String(UInt32.random(in: .min ... .max), radix: 16)
            let name = "h-" + String(repeating: "0", count: 8 - hex.count) + hex + ".sock"
            path = folder.appendingPathComponent(name, isDirectory: false).path
            if !FileManager.default.fileExists(atPath: path) { break }
        }
        return path
    }

    /// A socket's path in `folder`, which must fit the system's limit on
    /// one (104 bytes on a Mac). The session's id is a client's: any
    /// character of it but a letter, a digit, `-` or `_` is `_` here, so
    /// the socket is always a file of `folder`'s own (the random tag keeps
    /// two sessions' apart).
    static func socketPath(for session: String, in folder: URL) -> String {
        let tag = String(UUID().uuidString.prefix(6)).lowercased()
        let name = String(decoding: session.utf8.map { byte -> UInt8 in
            let kept = (0x30...0x39).contains(byte) || (0x41...0x5a).contains(byte) || (0x61...0x7a).contains(byte) || byte == 0x2d
            return kept || byte == 0x5f ? byte : 0x5f
        }, as: UTF8.self)
        let path = folder.appendingPathComponent("\(name)-\(tag).sock", isDirectory: false).path
        if path.utf8.count < 100 { return path }
        return folder.appendingPathComponent("\(name.prefix(8))-\(tag).sock", isDirectory: false).path
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

    package func write(_ object: [String: Any]) {
        guard isRunning, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        send(.input(data + Data([0x0A])))
    }

    package func closeInput() {
        if isRunning { send(.closeInput) }
    }

    package func end(grace: Duration) async {
        closeInput()
        let force = Task {
            try await Task.sleep(for: grace)
            if isRunning { send(.signal(.terminate)) }
            try await Task.sleep(for: .seconds(1))
            if isRunning { send(.signal(.kill)) }
            // A host that does not answer is ended itself.
            try await Task.sleep(for: .seconds(2))
            if isRunning {
                if hostPID > 0 { SystemPlatform.current.processes.kill(hostPID) }
                ended(AgentExit(status: -1, signaled: true))
            }
        }
        _ = await exit.value
        force.cancel()
    }

    /// Lets the agent go on without this server, which is going: the next
    /// one picks it up.
    package func detach() {
        detached = true
        stream?.close()
        stream = nil
    }

    /// The most memory the agent and what it runs may use (0: no limit).
    package func limit(_ bytes: UInt64) {
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
