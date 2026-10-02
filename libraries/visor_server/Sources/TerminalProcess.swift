// The agent's own terminal interface as a session: the command on a PTY
// that is the child's controlling terminal, its output streamed to
// whoever watches, keystrokes and resizes taken from them. What the user
// says from the chat is typed in, pasted, and entered.
//
// The session's transcript is not read from here — Claude Code writes it
// to its session file, which the server follows — so this process only
// announces the session id it learns (a new session's file appears in the
// project directory after launch) and the bytes.

import ClaudeTranscript
import Darwin
import Foundation
import Synchronization
import VisorProtocol

/// Whether a terminal's agent is at its input box, told from what it
/// draws. Kept by whoever reads the terminal, off the main actor.
struct TerminalReadiness {
    let agent: AgentKind
    /// The last stretch of what the terminal showed, as text.
    private var recent = ""
    private(set) var ready = false

    init(agent: AgentKind) { self.agent = agent }

    /// Claude Code's screen says where it is: its input box comes with
    /// "? for shortcuts" (and the mode line's "shift+tab to cycle", or
    /// "esc to interrupt" while it works); a prompt to be answered — trust
    /// this folder, accept bypass mode, allow this tool — ends with "Enter
    /// to confirm · Esc to cancel". What the chat sends is typed only at
    /// the input box, never into a prompt.
    mutating func observe(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        recent = String((recent + text).suffix(6000))
        let stripped = recent.replacingOccurrences(of: "\u{1B}\\[[0-9;?<>=]*[A-Za-z]", with: "", options: .regularExpression)
        let promptAt = max(stripped.range(of: "to confirm", options: .backwards)?.lowerBound.utf16Offset(in: stripped) ?? -1,
                           stripped.range(of: "Esc to cancel", options: .backwards)?.lowerBound.utf16Offset(in: stripped) ?? -1)
        let boxAt = ["for shortcuts", "shift+tab to cycle", "esc to interrupt"].map {
            stripped.range(of: $0, options: .backwards)?.lowerBound.utf16Offset(in: stripped) ?? -1
        }.max() ?? -1
        // The openrouter CLI's input box is its "›" prompt.
        ready = agent == .openrouter ? stripped.hasSuffix("› ") : boxAt > promptAt
    }
}

/// A child on a pseudo-terminal: the master end here, the slave its
/// controlling terminal.
@MainActor
private final class TerminalChild {
    let pid: pid_t
    private let master: Int32
    /// The other end, held open: it is the terminal (the master is not, and
    /// refuses TIOCSWINSZ on Darwin), and while we hold it the master never
    /// sees the end of the stream just because the agent closed its own.
    private let terminal: Int32
    /// What it draws, as it draws it, with whether it is at its input box
    /// by then.
    let output: AsyncStream<(bytes: Data, ready: Bool)>
    /// Done once it has exited and been reaped.
    let exit: Task<Void, Never>
    private(set) var exited = false

    init(executable: String, arguments: [String], directory: String, environment: [String: String],
         cols: Int, rows: Int, agent: AgentKind) throws {
        // The PTY: the master is ours, the slave is the child's terminal.
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let slave = ptsname(master) else {
            if master >= 0 { close(master) }
            throw AgentProcessError.spawnFailed("could not open a pseudo-terminal")
        }
        let slavePath = String(cString: slave)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        // Our own handle on the terminal, opened before the agent is
        // started so its first paint is already the right shape.
        let terminal = open(slavePath, O_RDWR | O_NOCTTY)
        guard terminal >= 0 else {
            close(master)
            throw AgentProcessError.spawnFailed("could not open the terminal")
        }
        _ = fcntl(terminal, F_SETFD, FD_CLOEXEC)
        Self.setSize(terminal, cols: cols, rows: rows)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        // Opened after setsid, so the slave becomes the child's controlling
        // terminal: Ctrl-C, job control and resize signals all arrive.
        posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        // The child's own directory, not ours changed around the spawn.
        posix_spawn_file_actions_addchdir_np(&actions, directory)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var child: pid_t = 0
        let result = posix_spawn(&child, executable, &actions, &attributes, argv, envp)
        guard result == 0 else {
            close(terminal)
            close(master)
            throw AgentProcessError.spawnFailed("\((executable as NSString).lastPathComponent) could not be started (\(result))")
        }
        pid = child
        self.master = master
        self.terminal = terminal

        // The agent's own end is held open here, so the stream never ends
        // on its own: the process itself says when it is gone.
        let queue = DispatchQueue(label: "visor.terminal")
        let reading = Self.reading(master: master, terminal: terminal, agent: agent, on: queue)
        output = reading.output
        let exits = Self.watching(child, reader: reading.source, on: queue)
        exit = Task { for await _ in exits {} }
        Task { [weak self] in
            await self?.exit.value
            self?.exited = true
        }
    }

    /// What the terminal draws, read on a queue of its own as it is drawn.
    /// The descriptors close once the reading is cancelled.
    private nonisolated static func reading(master: Int32, terminal: Int32, agent: AgentKind, on queue: DispatchQueue)
        -> (source: DispatchSourceRead, output: AsyncStream<(bytes: Data, ready: Bool)>) {
        let (output, drawn) = AsyncStream.makeStream(of: (bytes: Data, ready: Bool).self)
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        let readiness = Mutex(TerminalReadiness(agent: agent))
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = read(master, &buffer, buffer.count)
            guard count > 0 else { return }
            let data = Data(buffer[0..<count])
            let ready = readiness.withLock { $0.observe(data); return $0.ready }
            drawn.yield((data, ready))
        }
        source.setCancelHandler {
            close(terminal)
            close(master)
            drawn.finish()
        }
        source.resume()
        return (source, output)
    }

    /// The child's exit: it is reaped, the reading stops, and the stream
    /// returned ends.
    private nonisolated static func watching(_ child: pid_t, reader: DispatchSourceRead, on queue: DispatchQueue) -> AsyncStream<Void> {
        let (exits, gone) = AsyncStream.makeStream(of: Void.self)
        let watcher = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
        watcher.setEventHandler {
            var status: Int32 = 0
            waitpid(child, &status, 0)
            watcher.cancel()
            reader.cancel()
            gone.finish()
        }
        watcher.resume()
        return exits
    }

    /// Tells the terminal its shape. On the slave: the master is not a
    /// terminal and answers ENOTTY, which left every session at the
    /// agent's own fallback width.
    private static func setSize(_ terminal: Int32, cols: Int, rows: Int) {
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = withUnsafeMutablePointer(to: &size) { ioctl(terminal, 0x8008_7467 /* TIOCSWINSZ */, $0) }
    }

    func resize(cols: Int, rows: Int) {
        guard !exited else { return }
        Self.setSize(terminal, cols: cols, rows: rows)
    }

    func write(_ data: Data) {
        guard !exited, !data.isEmpty else { return }
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(master, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    /// Ends it and returns when it is gone: asked to terminate, and after
    /// `grace` given no choice.
    func end(grace: Duration) async {
        guard !exited else { return }
        let pid = self.pid
        kill(pid, SIGTERM)
        let force = Task {
            try await Task.sleep(for: grace)
            kill(pid, SIGKILL)
        }
        await exit.value
        force.cancel()
    }
}

@MainActor
public final class TerminalProcess: AgentProcess, TerminalCapable {
    public let events: AsyncStream<AgentEvent>
    private let emit: AsyncStream<AgentEvent>.Continuation
    public var skipPermissions: Bool
    public var model: String?
    public var effort: String?
    public var approvalEnvironment: [String: String] = [:]

    private let agent: AgentKind
    private let cwd: String
    public private(set) var resumeID: String?
    /// The running agent. One that was stopped is no longer this, and what
    /// it still draws is not passed on.
    private var child: TerminalChild?
    private var cols = 120
    private var rows = 36
    /// Whether the agent is at its input box.
    public private(set) var ready = false

    public init(agent: AgentKind, cwd: String, skipPermissions: Bool, resume: String?) {
        self.agent = agent
        self.cwd = cwd
        self.skipPermissions = skipPermissions
        self.resumeID = resume
        (events, emit) = AsyncStream.makeStream()
    }

    public var resumeCommand: String? {
        guard let id = resumeID else { return nil }
        switch agent {
        case .claude: return "cd \(ClaudeProcess.quoted(cwd)) && claude --resume \(id)"
        case .codex: return "cd \(ClaudeProcess.quoted(cwd)) && codex resume \(id)"
        case .openrouter: return "cd \(ClaudeProcess.quoted(cwd)) && openrouter --resume \(id)"
        }
    }
    public var processID: Int32? { child?.pid }

    private var tool: String { agent.tool }

    public func start() throws {
        _ = try running()
    }

    /// What the user said in the chat, typed in as a paste and entered.
    public func send(_ text: String) throws {
        let child = try running()
        var bytes = Data()
        bytes.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]) // ESC[200~ bracketed paste
        bytes.append(contentsOf: Array(text.utf8))
        bytes.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]) // ESC[201~
        bytes.append(0x0D)
        child.write(bytes)
        emit.yield(.busy(true))
    }

    public func write(_ data: Data) {
        child?.write(data)
    }

    public func resize(cols: Int, rows: Int) {
        self.cols = max(20, cols)
        self.rows = max(5, rows)
        child?.resize(cols: self.cols, rows: self.rows)
    }

    /// Tells the agent its window changed and changed back. A terminal
    /// only signals when the shape differs, so this is the way to ask a
    /// full-screen interface — which owns every cell and never reflows —
    /// to paint itself again for a window that has just attached.
    public func repaint() {
        guard let child, cols > 20 else { return }
        child.resize(cols: cols - 1, rows: rows)
        child.resize(cols: cols, rows: rows)
    }

    /// Escape: the agent's own interrupt of the turn in flight.
    public func interrupt() {
        child?.write(Data([0x1B]))
    }

    /// Ends the terminal: the session is being archived, ended or handed
    /// to the chat process.
    public func stop() {
        guard let child = release() else { return }
        Task { await child.end(grace: .seconds(2)) }
    }

    public func end(within deadline: Duration) async {
        guard let child = release() else { return }
        await child.end(grace: max(.milliseconds(500), deadline - .seconds(1)))
    }

    /// Lets go of the running agent, for whoever is ending it: from here
    /// the session is idle, and the agent's exit is expected.
    private func release() -> TerminalChild? {
        guard let child else { return nil }
        self.child = nil
        ready = false
        emit.yield(.activity(nil))
        emit.yield(.busy(false))
        return child
    }

    /// The running agent, started if there is none.
    private func running() throws -> TerminalChild {
        if let child { return child }
        guard let executable = ToolPath.resolve(tool) else { throw AgentProcessError.toolMissing(tool) }
        // The command line: the agent, its launch flags, and the session
        // to pick up.
        var arguments: [String] = []
        // The id was made here (a new openrouter session): say so once it runs.
        var announce: String?
        switch agent {
        case .openrouter:
            // The CLI takes the id up front, so the session is known from
            // the start (Claude's is discovered from its file instead).
            if let model, !model.isEmpty { arguments += ["--model", model] }
            if let effort, !effort.isEmpty { arguments += ["--effort", effort] }
            if let resumeID {
                arguments += ["--resume", resumeID]
            } else {
                let id = UUID().uuidString.lowercased()
                resumeID = id
                announce = id
                arguments += ["--session-id", id]
            }
        case .claude:
            if skipPermissions { arguments.append("--dangerously-skip-permissions") }
            if let model, !model.isEmpty { arguments += ["--model", model] }
            if let effort, !effort.isEmpty { arguments += ["--effort", effort] }
            if let resumeID { arguments += ["--resume", resumeID] }
        case .codex:
            if let resumeID { arguments += ["resume", resumeID] }
            if skipPermissions { arguments.append("--dangerously-bypass-approvals-and-sandbox") }
            if let model, !model.isEmpty { arguments += ["-m", model] }
        }
        var environment = ToolPath.environment()
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        for (key, value) in approvalEnvironment { environment[key] = value }

        // Files in the project directory before launch: a new session's
        // file is the one that appears after.
        let before = resumeID == nil && agent == .claude ? Set(Self.sessionFiles(cwd: cwd)) : nil
        let child = try TerminalChild(executable: executable, arguments: arguments,
                                      directory: (cwd as NSString).expandingTildeInPath, environment: environment,
                                      cols: cols, rows: rows, agent: agent)
        self.child = child
        ready = false
        let tool = self.tool
        // Everything it draws, in order, and then that it is gone.
        Task { [weak self] in
            for await drawn in child.output {
                guard let self else { return }
                guard self.child === child else { continue }
                let wasReady = self.ready
                self.ready = drawn.ready
                self.emit.yield(.tty(drawn.bytes))
                // Ready again: the server hands over what waited.
                if drawn.ready, !wasReady { self.emit.yield(.busy(false)) }
            }
            await child.exit.value
            guard let self, self.child === child else { return }
            self.child = nil
            self.ready = false
            self.emit.yield(.activity(nil))
            self.emit.yield(.busy(false))
            self.emit.yield(.failure("\(tool) exited"))
        }
        if let announce { emit.yield(.session(announce)) }
        if let before {
            // A new session: its file appears in the project directory once
            // the agent has written its first record.
            Task { [weak self] in await self?.discoverSession(of: child, before: before) }
        }
        return child
    }

    /// Looks for the session file a new Claude Code session writes, for as
    /// long as the agent that would write it runs (five minutes at most).
    private func discoverSession(of child: TerminalChild, before: Set<String>) async {
        let cwd = self.cwd
        let deadline = ContinuousClock.now + .seconds(300)
        while resumeID == nil, self.child === child, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(500))
            let now = await Self.listSessionFiles(cwd: cwd)
            guard resumeID == nil, self.child === child else { return }
            if let name = Set(now).subtracting(before).sorted().first {
                let id = String(name.dropLast(".jsonl".count))
                resumeID = id
                emit.yield(.session(id))
                return
            }
        }
    }

    @concurrent
    private nonisolated static func listSessionFiles(cwd: String) async -> [String] { sessionFiles(cwd: cwd) }

    private nonisolated static func sessionFiles(cwd: String) -> [String] {
        let directory = ClaudeSessionFiles.projectsRoot().appendingPathComponent(ClaudeSessionFiles.projectDirectoryName(for: cwd))
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".jsonl") }
    }
}
