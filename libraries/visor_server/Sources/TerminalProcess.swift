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
import VisorProtocol

public final class TerminalProcess: AgentProcess, TerminalCapable {
    public var onEvent: (@Sendable (AgentEvent) -> Void)?
    public var skipPermissions: Bool
    public var model: String?
    public var effort: String?
    public var onModel: (@Sendable (String) -> Void)?
    public var approvalEnvironment: [String: String] = [:]

    private let agent: AgentKind
    private let cwd: String
    private var sessionID: String?
    /// The id was made here (a new openrouter session): say so once it runs.
    private var announceSession = false
    private var pid: pid_t = 0
    private var master: Int32 = -1
    /// The other end, held open: it is the terminal (the master is not, and
    /// refuses TIOCSWINSZ on Darwin), and while we hold it the master never
    /// sees the end of the stream just because the agent closed its own.
    private var terminalFD: Int32 = -1
    private var reader: DispatchSourceRead?
    private var watcher: DispatchSourceProcess?
    private var cols = 120
    private var rows = 36
    private var stopping = false
    private let queue = DispatchQueue(label: "visor.terminal")
    /// The last stretch of what the terminal showed, as text, for telling
    /// the input box from a prompt.
    private var recent = ""
    private var isReady = false
    public var ready: Bool { queue.sync { isReady } }
    public var size: (cols: Int, rows: Int) { queue.sync { (cols, rows) } }

    public init(agent: AgentKind, cwd: String, skipPermissions: Bool, resume: String?) {
        self.agent = agent
        self.cwd = cwd
        self.skipPermissions = skipPermissions
        self.sessionID = resume
    }

    public var resumeID: String? { queue.sync { sessionID } }
    public var resumeCommand: String? {
        guard let id = resumeID else { return nil }
        switch agent {
        case .claude: return "cd \(ClaudeProcess.quoted(cwd)) && claude --resume \(id)"
        case .codex: return "cd \(ClaudeProcess.quoted(cwd)) && codex resume \(id)"
        case .openrouter: return "cd \(ClaudeProcess.quoted(cwd)) && openrouter --resume \(id)"
        }
    }
    public var processID: Int32? { queue.sync { pid > 0 ? pid : nil } }

    private var tool: String { agent.tool }

    /// The command line: the agent, its launch flags, and the session to
    /// pick up.
    private var arguments: [String] {
        var args: [String] = []
        switch agent {
        case .openrouter:
            // The CLI takes the id up front, so the session is known from
            // the start (Claude's is discovered from its file instead).
            if sessionID == nil { sessionID = UUID().uuidString.lowercased(); announceSession = true }
            if let model, !model.isEmpty { args += ["--model", model] }
            if let effort, !effort.isEmpty { args += ["--effort", effort] }
            if let sessionID { args += [announceSession ? "--session-id" : "--resume", sessionID] }
        case .claude:
            if skipPermissions { args.append("--dangerously-skip-permissions") }
            if let model, !model.isEmpty { args += ["--model", model] }
            if let effort, !effort.isEmpty { args += ["--effort", effort] }
            if let sessionID { args += ["--resume", sessionID] }
        case .codex:
            if let sessionID { args += ["resume", sessionID] }
            if skipPermissions { args.append("--dangerously-bypass-approvals-and-sandbox") }
            if let model, !model.isEmpty { args += ["-m", model] }
        }
        return args
    }

    public func start() throws {
        try queue.sync { try spawnIfNeeded() }
    }

    /// What the user said in the chat, typed in as a paste and entered.
    public func send(_ text: String) throws {
        try queue.sync {
            try spawnIfNeeded()
            var bytes = Data()
            bytes.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]) // ESC[200~ bracketed paste
            bytes.append(contentsOf: Array(text.utf8))
            bytes.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]) // ESC[201~
            bytes.append(0x0D)
            writeBytes(bytes)
            onEvent?(.busy(true))
        }
    }

    public func write(_ data: Data) {
        queue.sync { writeBytes(data) }
    }

    public func resize(cols: Int, rows: Int) {
        queue.sync {
            self.cols = max(20, cols)
            self.rows = max(5, rows)
            applySize()
        }
    }

    /// Tells the terminal its shape. On the slave: the master is not a
    /// terminal and answers ENOTTY, which left every session at the
    /// agent's own fallback width.
    private func applySize() {
        guard terminalFD >= 0 else { return }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = withUnsafeMutablePointer(to: &size) { ioctl(terminalFD, 0x8008_7467 /* TIOCSWINSZ */, $0) }
    }

    /// Tells the agent its window changed and changed back. A terminal
    /// only signals when the shape differs, so this is the way to ask a
    /// full-screen interface — which owns every cell and never reflows —
    /// to paint itself again for a window that has just attached.
    public func repaint() {
        queue.sync {
            guard terminalFD >= 0, cols > 20 else { return }
            let real = cols
            cols = real - 1
            applySize()
            cols = real
            applySize()
        }
    }

    /// Escape: the agent's own interrupt of the turn in flight.
    public func interrupt() {
        queue.sync { writeBytes(Data([0x1B])) }
    }

    /// Ends the terminal: the session is being archived, ended or handed
    /// to the chat process.
    public func stop() {
        stopAndWait(deadline: 3)
    }

    public func stopAndWait(deadline: TimeInterval) {
        let running: pid_t = queue.sync {
            stopping = true
            return pid
        }
        guard running > 0 else { return }
        kill(running, SIGTERM)
        let grace = Date().addingTimeInterval(max(0.5, deadline - 1))
        while Date() < grace, kill(running, 0) == 0 { usleep(50_000) }
        if kill(running, 0) == 0 { kill(running, SIGKILL) }
        var status: Int32 = 0
        waitpid(running, &status, 0)
        queue.sync { closeMaster(); pid = 0 }
        onEvent?(.activity(nil))
        onEvent?(.busy(false))
    }

    private func writeBytes(_ data: Data) {
        guard master >= 0, !data.isEmpty else { return }
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(master, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    private func closeMaster() {
        reader?.cancel()
        reader = nil
        watcher?.cancel()
        watcher = nil
        if terminalFD >= 0 { close(terminalFD); terminalFD = -1 }
        if master >= 0 { close(master); master = -1 }
    }

    private func spawnIfNeeded() throws {
        guard pid == 0 else { return }
        guard let executable = ToolPath.resolve(tool) else { throw AgentProcessError.toolMissing(tool) }
        // The PTY: the master is ours, the slave is the child's terminal.
        let m = posix_openpt(O_RDWR | O_NOCTTY)
        guard m >= 0, grantpt(m) == 0, unlockpt(m) == 0, let slave = ptsname(m) else {
            throw AgentProcessError.spawnFailed("could not open a pseudo-terminal")
        }
        let slavePath = String(cString: slave)
        _ = fcntl(m, F_SETFD, FD_CLOEXEC)
        // Our own handle on the terminal, opened before the agent is
        // started so its first paint is already the right shape.
        let s = open(slavePath, O_RDWR | O_NOCTTY)
        guard s >= 0 else {
            close(m)
            throw AgentProcessError.spawnFailed("could not open the terminal")
        }
        _ = fcntl(s, F_SETFD, FD_CLOEXEC)
        master = m
        terminalFD = s
        applySize()

        // Files in the project directory before launch: a new session's
        // file is the one that appears after.
        let before = Set(Self.sessionFiles(cwd: cwd))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        // Opened after setsid, so the slave becomes the child's controlling
        // terminal: Ctrl-C, job control and resize signals all arrive.
        posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        var environment = ToolPath.environment()
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        for (key, value) in approvalEnvironment { environment[key] = value }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        let directory = (cwd as NSString).expandingTildeInPath
        let previous = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(directory)
        var child: pid_t = 0
        let result = posix_spawn(&child, executable, &actions, &attributes, argv, envp)
        FileManager.default.changeCurrentDirectoryPath(previous)
        guard result == 0 else {
            closeMaster()
            throw AgentProcessError.spawnFailed("\(tool) could not be started (\(result))")
        }
        pid = child
        stopping = false

        // The agent's own end is held open here, so the stream never ends
        // on its own: the process itself says when it is gone.
        let watcher = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
        watcher.setEventHandler { [weak self] in self?.exited() }
        watcher.resume()
        self.watcher = watcher

        let source = DispatchSource.makeReadSource(fileDescriptor: m, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, self.master >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let n = read(self.master, &buffer, buffer.count)
            if n > 0 {
                let data = Data(buffer[0..<n])
                self.observe(data)
                self.onEvent?(.tty(data))
            }
        }
        source.resume()
        reader = source

        if announceSession, let id = sessionID {
            announceSession = false
            onEvent?(.session(id))
        }
        if sessionID == nil, agent == .claude {
            // A new session: its file appears in the project directory once
            // the agent has written its first record.
            let started = Date()
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.discoverSession(before: before, since: started) }
        }
    }

    /// Claude Code's screen says where it is: its input box comes with
    /// "? for shortcuts" (and the mode line's "shift+tab to cycle", or
    /// "esc to interrupt" while it works); a prompt to be answered — trust
    /// this folder, accept bypass mode, allow this tool — ends with "Enter
    /// to confirm · Esc to cancel". What the chat sends is typed only at
    /// the input box, never into a prompt.
    private func observe(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        recent = String((recent + text).suffix(6000))
        let stripped = recent.replacingOccurrences(of: "\u{1B}\\[[0-9;?<>=]*[A-Za-z]", with: "", options: .regularExpression)
        let promptAt = max(stripped.range(of: "to confirm", options: .backwards)?.lowerBound.utf16Offset(in: stripped) ?? -1,
                           stripped.range(of: "Esc to cancel", options: .backwards)?.lowerBound.utf16Offset(in: stripped) ?? -1)
        let boxAt = ["for shortcuts", "shift+tab to cycle", "esc to interrupt"].map {
            stripped.range(of: $0, options: .backwards)?.lowerBound.utf16Offset(in: stripped) ?? -1
        }.max() ?? -1
        // The openrouter CLI's input box is its "›" prompt.
        let now = agent == .openrouter ? stripped.hasSuffix("› ") : boxAt > promptAt
        guard now != isReady else { return }
        isReady = now
        // Ready again: the server hands over what waited.
        if now { onEvent?(.busy(false)) }
    }

    private func discoverSession(before: Set<String>, since: Date) {
        guard sessionID == nil, pid > 0 else { return }
        let now = Set(Self.sessionFiles(cwd: cwd))
        if let name = now.subtracting(before).sorted().first {
            let id = String(name.dropLast(".jsonl".count))
            sessionID = id
            onEvent?(.session(id))
            return
        }
        guard Date().timeIntervalSince(since) < 300 else { return }
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.discoverSession(before: before, since: since) }
    }

    private static func sessionFiles(cwd: String) -> [String] {
        let directory = ClaudeSessionFiles.projectsRoot().appendingPathComponent(ClaudeSessionFiles.projectDirectoryName(for: cwd))
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".jsonl") }
    }

    private func exited() {
        let child = pid
        var status: Int32 = 0
        if child > 0 { waitpid(child, &status, WNOHANG) }
        closeMaster()
        pid = 0
        let expected = stopping
        stopping = false
        onEvent?(.activity(nil))
        onEvent?(.busy(false))
        if !expected { onEvent?(.failure("\(tool) exited")) }
    }
}
