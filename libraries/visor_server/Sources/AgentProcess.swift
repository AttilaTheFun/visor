// An agent as a subprocess: something that takes user turns and yields
// normalised events. Claude Code and Codex differ in how they are driven
// (one long-lived process fed on stdin; one process per turn, resumed by
// id) and in their JSON; each adapter hides that.

import Foundation
import VisorProtocol

public enum AgentEvent: Sendable {
    /// More of the reply being written.
    /// Words streamed for the assistant message with this id.
    case delta(message: String, text: String)
    /// A finished entry, or a replacement for the entry with the same id.
    case entry(TranscriptEntry)
    /// What the agent is doing now, or nothing (one line, for a list).
    case activity(String?)
    /// The model is thinking, or has stopped.
    case thinking(Bool)
    /// A tool call began: what it is, for the turn's status; for a task
    /// list tool, the list as written.
    case toolStarted(id: String, name: String, label: String, tasks: [TaskItem]?)
    /// The tool with this id finished.
    case toolFinished(id: String)
    case busy(Bool)
    /// A failure to show under the transcript.
    case failure(String)
    /// The tokens the last request carried, and the model's window: how
    /// full the agent's context is.
    case context(used: Int, limit: Int?)
    /// The agent's own session id, once it has one: where its transcript
    /// file is.
    case session(String)
    /// Bytes a terminal produced.
    case tty(Data)
}

/// A process on a PTY: it takes what the user types and can be resized.
public protocol TerminalCapable: AnyObject {
    func write(_ data: Data)
    func resize(cols: Int, rows: Int)
    /// The agent's own interrupt of the turn in flight (Escape).
    func interrupt()
    /// Makes the agent draw its whole screen again. A full-screen
    /// interface owns every cell and repaints on its own terms, so this
    /// is how a window that has just attached is given the truth.
    func repaint()
    /// Whether the agent is at its input box, rather than a startup or
    /// permission prompt that typed text would answer with its default.
    var ready: Bool { get }
    /// The terminal's size, in cells: what its output was drawn for.
    var size: (cols: Int, rows: Int) { get }
    /// Launches it now; a terminal is live before anything is said.
    func start() throws
}

public protocol AgentProcess: AnyObject {
    /// Called on an arbitrary queue with each event.
    var onEvent: (@Sendable (AgentEvent) -> Void)? { get set }
    /// Auto (no prompts) or manual; takes effect when the agent next
    /// (re)spawns — Codex each turn, Claude after `stop`.
    var skipPermissions: Bool { get set }
    /// The model and effort flags; nil leaves the provider's default. Take
    /// effect when the agent next (re)spawns, like `skipPermissions`.
    var model: String? { get set }
    var effort: String? { get set }
    /// Called when the agent reports which model it actually runs.
    var onModel: (@Sendable (String) -> Void)? { get set }
    /// How the agent reaches the app: the port and the agent-side token,
    /// plus this session's id. The permission shim is given it in manual
    /// mode, and the agent itself always has it in its environment — that
    /// is how a session knows which session it is (VISOR_SESSION) and can
    /// ask the server to restart into it.
    var approvalEnvironment: [String: String] { get set }
    /// The agent's own session id (Claude's session, Codex's thread), once
    /// a turn has started it; what `resumeCommand` and unarchiving use.
    var resumeID: String? { get }
    /// The terminal command that resumes the same session, once known.
    var resumeCommand: String? { get }
    /// Sends a user turn; spawns (or resumes) the process as needed.
    func send(_ text: String) throws
    /// Ends the turn in flight but keeps the process, so the next message
    /// carries straight on in it. Where an agent has no way to end a turn
    /// without ending the process, this is `stop`.
    func interrupt()
    /// Ends the running process — gracefully (stdin closed, a moment to
    /// exit) then by force; the transcript and the agent's own session
    /// survive, so the next `send` resumes it.
    func stop()
    /// Ends it and does not return until it is gone (or `deadline`
    /// seconds have passed, after which it is killed outright). `stop`
    /// schedules the force step for later, which is no use to a quitting
    /// app: it exits first and leaves the agent running with nobody on
    /// the other end of its pipes.
    func stopAndWait(deadline: TimeInterval)
    /// The running agent's pid, written down so a later launch can
    /// recognise one of ours that outlived us.
    var processID: Int32? { get }
    /// Gives an agent the conversation so far, for one that keeps its own
    /// context in memory rather than a file it can re-read (OpenRouter).
    /// Called once, before the first turn of a resumed session.
    func seed(history: [TranscriptEntry])
}

public extension AgentProcess {
    /// Without its own way to end a turn, an interrupt is a stop: the
    /// process goes, and the next message spawns another that resumes.
    func interrupt() { stop() }
    /// Most agents re-read their own transcript; nothing to seed.
    func seed(history: [TranscriptEntry]) {}
}

public enum AgentProcessError: LocalizedError {
    case toolMissing(String)
    case spawnFailed(String)

    public var errorDescription: String? {
        switch self {
        case .toolMissing(let name): "\(name) is not installed on the host (not found on the login shell's PATH)"
        case .spawnFailed(let message): message
        }
    }
}

/// Splits a pipe's output into lines and hands each to a handler.
final class LineReader {
    private var buffer = Data()
    private let handler: (String) -> Void

    init(handle: FileHandle, handler: @escaping (String) -> Void) {
        self.handler = handler
        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if data.isEmpty {
                fh.readabilityHandler = nil
                self?.flush()
                return
            }
            self?.append(data)
        }
    }

    private func append(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let text = String(data: line, encoding: .utf8), !text.isEmpty { handler(text) }
        }
    }

    private func flush() {
        if !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8) { handler(text) }
        buffer.removeAll()
    }
}

/// Where the agents' command-line tools live. A GUI app's PATH has none of
/// the developer directories, so the login shell is asked once per tool.
public enum ToolPath {
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    public static func resolve(_ name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[name] { return hit }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin", "/usr/bin"]
        for dir in candidates where FileManager.default.isExecutableFile(atPath: "\(dir)/\(name)") {
            cache[name] = "\(dir)/\(name)"
            return cache[name]
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v \(name)"]
        let out = Pipe()
        shell.standardOutput = out
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, shell.terminationStatus == 0 else { return nil }
        cache[name] = path
        return path
    }

    /// The environment for a spawned agent: ours, with the developer
    /// directories on PATH and any trace of a surrounding Claude Code
    /// session removed (a nested session refuses to start).
    public static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.claude/local"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") { env.removeValue(forKey: key) }
        return env
    }
}

/// JSON helpers over JSONSerialization (the agents' streams are loosely typed).
enum JSON {
    static func object(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func string(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        return nil
    }

    /// A short, one-line summary of a tool's input for an activity label.
    static func summary(_ input: Any?, limit: Int = 80) -> String {
        guard let dict = input as? [String: Any] else { return "" }
        let preferred = ["command", "file_path", "path", "pattern", "query", "url", "description", "prompt", "notebook_path"]
        var text = ""
        for key in preferred {
            if let value = dict[key] as? String, !value.isEmpty { text = value; break }
        }
        if text.isEmpty, let first = dict.values.compactMap({ $0 as? String }).first { text = first }
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }
}
