// An agent as a subprocess: something that takes user turns and yields
// normalised events. Claude Code and Codex differ in how they are driven
// (one long-lived process fed on stdin; one process per turn, resumed by
// id) and in their JSON; each adapter hides that.
//
// A process is driven from the main actor, where the server keeps its
// sessions. What the agent says is read and parsed off it, and reaches
// the server as a stream of events, in the order the agent said them.

import Foundation
import Synchronization
import VisorProtocol

public enum AgentEvent: Sendable {
    /// More of the reply being written.
    /// Words streamed for the assistant message with this id.
    case delta(message: String, text: String)
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
    /// The slash commands the agent takes, as it lists them.
    case commands([SlashCommand])
    /// The model the agent says it is actually running.
    case model(String)
}

/// A process on a PTY: it takes what the user types and can be resized.
@MainActor
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
    /// Launches it now; a terminal is live before anything is said.
    func start() throws
}

@MainActor
public protocol AgentProcess: AnyObject {
    /// What the agent does, in order. One listener: the session's record.
    var events: AsyncStream<AgentEvent> { get }
    /// Auto (no prompts) or manual; takes effect when the agent next
    /// (re)spawns — Codex each turn, Claude after `stop`.
    var skipPermissions: Bool { get set }
    /// The model and effort flags; nil leaves the provider's default. Take
    /// effect when the agent next (re)spawns, like `skipPermissions`.
    var model: String? { get set }
    var effort: String? { get set }
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
    /// exit) then by force — without waiting for it; the transcript and
    /// the agent's own session survive, so the next `send` resumes it.
    func stop()
    /// Ends it and returns once it is gone: asked to go, then after
    /// `deadline` made to. What a quitting app waits for (an agent left
    /// behind runs on with nobody at the other end of its pipes), and what
    /// comes before another agent is started on the same session.
    func end(within deadline: Duration) async
    /// The running agent's pid, written down so a later launch can
    /// recognise one of ours that outlived us.
    var processID: Int32? { get }
}

public extension AgentProcess {
    /// Without its own way to end a turn, an interrupt is a stop: the
    /// process goes, and the next message spawns another that resumes.
    func interrupt() { stop() }
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

/// Where the agents' command-line tools live. A GUI app's PATH has none of
/// the developer directories: the usual ones are looked in directly, and
/// the login shell is asked about a tool they do not have.
public enum ToolPath {
    /// What the login shell said of each tool it was asked about: where it
    /// is, or that it is not there.
    private static let asked = Mutex<[String: String?]>([:])

    private static var directories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin", "/usr/bin"]
    }

    /// Where a tool is, as far as is known without waiting: in one of the
    /// usual directories, or where the login shell last found it.
    public static func resolve(_ name: String) -> String? {
        for directory in directories where FileManager.default.isExecutableFile(atPath: "\(directory)/\(name)") {
            return "\(directory)/\(name)"
        }
        return asked.withLock { $0[name] ?? nil }
    }

    /// Asks the login shell where the tools are that the usual directories
    /// do not have, and remembers what it says. Starting a login shell
    /// takes a while, so this is done ahead of need and off the main actor.
    @concurrent
    public static func locate(_ names: [String]) async {
        for name in names where resolve(name) == nil {
            let answer = await Command.output("/bin/zsh", ["-lc", "command -v \(name)"])
            let path = answer?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let found = answer?.status == 0 && !path.isEmpty
            asked.withLock { $0[name] = found ? path : nil }
        }
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
