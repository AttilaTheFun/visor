// A terminal session: the user's login shell on a PTY that is its
// controlling terminal, in the session's folder, its output streamed to
// the window that has it, keystrokes and resizes taken from that window —
// what ssh to the computer would give. There is no transcript and no
// turn: the shell is typed into, and it draws. The terminal itself is the
// platform's (TerminalLaunching).

import Foundation
import Synchronization
import VisorProtocol

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
    public var processID: Int32? { child?.processID }

    private let cwd: String
    private let shell: ShellCommand
    /// The running shell. One that was stopped is no longer this, and what
    /// it still draws is not passed on.
    private var child: (any TerminalChild)?
    private var cols = 100
    private var rows = 30

    /// What the window is told when the shell has exited.
    static let exitedNote = "\r\n[The shell exited. Press any key for a new one.]\r\n"

    public init(cwd: String, shell: ShellCommand = ToolPath.loginShell()) {
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
    private func release() -> (any TerminalChild)? {
        guard let child else { return nil }
        self.child = nil
        return child
    }

    /// The running shell, started if there is none.
    private func running() throws -> any TerminalChild {
        if let child { return child }
        var environment = ToolPath.environment()
        // Nothing of the server's own sessions: this is the user's shell.
        for key in environment.keys where key.hasPrefix("VISOR_") { environment.removeValue(forKey: key) }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Visor"
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        environment["SHELL"] = shell.executable
        let directory = (cwd as NSString).expandingTildeInPath
        let child = try ServerPlatform.current.terminals.start(shell, directory: FileManager.default.fileExists(atPath: directory) ? directory : NSHomeDirectory(),
                                                              environment: environment, cols: cols, rows: rows)
        self.child = child
        // Everything it draws, in order, and then that it is gone.
        Task { [weak self] in
            for await bytes in child.output {
                guard let self else { return }
                guard self.child === child else { continue }
                self.emit.yield(.tty(bytes))
            }
            await child.exited()
            guard let self, self.child === child else { return }
            self.child = nil
            self.emit.yield(.tty(Data(Self.exitedNote.utf8)))
        }
        return child
    }
}
