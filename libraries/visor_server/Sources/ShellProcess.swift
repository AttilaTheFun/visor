// A terminal session: the user's login shell on a PTY that is its
// controlling terminal, in the session's folder, its output streamed to
// the window that has it, keystrokes and resizes taken from that window —
// what ssh to the computer would give. There is no transcript and no
// turn: the shell is typed into, and it draws.

import Darwin
import Foundation
import Synchronization
import VisorProtocol

/// A child on a pseudo-terminal: the master end here, the slave its
/// controlling terminal.
@MainActor
private final class TerminalChild {
    let pid: pid_t
    private let master: Int32
    /// The other end, held open: it is the terminal (the master is not, and
    /// refuses TIOCSWINSZ on Darwin), and while we hold it the master never
    /// sees the end of the stream just because the shell closed its own.
    private let terminal: Int32
    /// What it draws, as it draws it.
    let output: AsyncStream<Data>
    /// Done once it has exited and been reaped.
    let exit: Task<Void, Never>
    private(set) var exited = false

    init(executable: String, arguments: [String], directory: String, environment: [String: String],
         cols: Int, rows: Int) throws {
        // The PTY: the master is ours, the slave is the child's terminal.
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let slave = ptsname(master) else {
            if master >= 0 { close(master) }
            throw AgentProcessError.spawnFailed("could not open a pseudo-terminal")
        }
        let slavePath = String(cString: slave)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        // Our own handle on the terminal, opened before the shell is
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

        // The child's own end is held open here, so the stream never ends
        // on its own: the process itself says when it is gone.
        let queue = DispatchQueue(label: "visor.terminal")
        let reading = Self.reading(master: master, terminal: terminal, on: queue)
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
    private nonisolated static func reading(master: Int32, terminal: Int32, on queue: DispatchQueue)
        -> (source: DispatchSourceRead, output: AsyncStream<Data>) {
        let (output, drawn) = AsyncStream.makeStream(of: Data.self)
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = read(master, &buffer, buffer.count)
            guard count > 0 else { return }
            drawn.yield(Data(buffer[0..<count]))
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
    /// terminal and answers ENOTTY.
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
public final class ShellProcess: AgentProcess, TerminalCapable {
    public let events: AsyncStream<AgentEvent>
    private let emit: AsyncStream<AgentEvent>.Continuation
    // A shell has no permission mode, model or effort; kept for the
    // process interface.
    public var skipPermissions = false
    public var model: String?
    public var effort: String?
    public var approvalEnvironment: [String: String] = [:]
    public var resumeID: String? { nil }
    public var resumeCommand: String? { nil }
    public var processID: Int32? { child?.pid }

    private let cwd: String
    private let shell: String
    /// The running shell. One that was stopped is no longer this, and what
    /// it still draws is not passed on.
    private var child: TerminalChild?
    private var cols = 100
    private var rows = 30

    /// What the window is told when the shell has exited.
    static let exitedNote = "\r\n[The shell exited. Press any key for a new one.]\r\n"

    public init(cwd: String, shell: String = ToolPath.loginShell()) {
        self.cwd = cwd
        self.shell = shell
        (events, emit) = AsyncStream.makeStream()
    }

    public func start() throws {
        _ = try running()
    }

    /// A line, typed in and entered.
    public func send(_ text: String) throws {
        try running().write(Data((text + "\r").utf8))
    }

    /// What the window typed. With the shell gone, a key starts another
    /// and is not passed on: it was pressed to get a prompt back.
    public func write(_ data: Data) {
        guard let child else {
            do { try start() } catch { emit.yield(.failure(error.localizedDescription)) }
            return
        }
        child.write(data)
    }

    public func resize(cols: Int, rows: Int) {
        self.cols = max(20, cols)
        self.rows = max(5, rows)
        child?.resize(cols: self.cols, rows: self.rows)
    }

    /// Tells the shell its window changed and changed back. A terminal
    /// only signals when the shape differs, so this is the way to have a
    /// full-screen program (an editor, `top`) or the line editor draw
    /// itself again for a window that has just attached.
    public func repaint() {
        guard let child, cols > 20 else { return }
        child.resize(cols: cols - 1, rows: rows)
        child.resize(cols: cols, rows: rows)
    }

    /// Ctrl-C, as the keyboard would send it.
    public func interrupt() {
        child?.write(Data([0x03]))
    }

    /// Ends the shell: the session is being archived, ended or restarted.
    public func stop() {
        guard let child = release() else { return }
        Task { await child.end(grace: .seconds(2)) }
    }

    public func end(within deadline: Duration) async {
        guard let child = release() else { return }
        await child.end(grace: max(.milliseconds(500), deadline - .seconds(1)))
    }

    /// Lets go of the running shell, for whoever is ending it: its exit is
    /// expected, and not reported.
    private func release() -> TerminalChild? {
        guard let child else { return nil }
        self.child = nil
        return child
    }

    /// The running shell, started if there is none.
    private func running() throws -> TerminalChild {
        if let child { return child }
        var environment = ToolPath.environment()
        // Nothing of the server's own sessions: this is the user's shell.
        for key in environment.keys where key.hasPrefix("VISOR_") { environment.removeValue(forKey: key) }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Visor"
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        environment["SHELL"] = shell
        let directory = (cwd as NSString).expandingTildeInPath
        let child = try TerminalChild(executable: shell, arguments: ["-l"],
                                      directory: FileManager.default.fileExists(atPath: directory) ? directory : NSHomeDirectory(),
                                      environment: environment, cols: cols, rows: rows)
        self.child = child
        // Everything it draws, in order, and then that it is gone.
        Task { [weak self] in
            for await bytes in child.output {
                guard let self else { return }
                guard self.child === child else { continue }
                self.emit.yield(.tty(bytes))
            }
            await child.exit.value
            guard let self, self.child === child else { return }
            self.child = nil
            self.emit.yield(.tty(Data(Self.exitedNote.utf8)))
        }
        return child
    }
}
