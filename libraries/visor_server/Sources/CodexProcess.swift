// Codex as a session: one `codex exec --json` process per turn — the first
// starts a thread, later ones `codex exec resume <thread>` — with the prompt
// on stdin. Its JSONL:
//   {"type":"thread.started","thread_id":…}
//   {"type":"turn.started"} … {"type":"turn.completed"} | {"type":"turn.failed","error":{"message":…}}
//   {"type":"item.started"|"item.updated"|"item.completed","item":{"id":…,"type":"agent_message"|"reasoning"|"command_execution"|"file_change"|"web_search"|"mcp_tool_call"|"error",…}}
//   {"type":"error","message":…}

import Foundation
import VisorProtocol

public final class CodexProcess: AgentProcess {
    public var onEvent: (@Sendable (AgentEvent) -> Void)?

    private let cwd: String
    public var skipPermissions: Bool
    public var model: String?
    public var effort: String?
    public var onModel: (@Sendable (String) -> Void)?
    /// Codex's headless runs never ask; manual mode is its sandbox.
    public var approvalEnvironment: [String: String] = [:]
    private var process: Process?
    private var reader: LineReader?
    private var stderrReader: LineReader?
    private var threadID: String?
    public var resumeID: String? { queue.sync { threadID } }
    public var resumeCommand: String? {
        guard let id = resumeID else { return nil }
        return "cd \(ClaudeProcess.quoted(cwd)) && codex resume \(id)"
    }
    private let queue = DispatchQueue(label: "visor.codex")
    private var turn = 0
    /// The turn's entries so far: a message after commands opens a new one,
    /// so what the agent said and what it ran keep their order.
    private var segment = 0
    private var turnText = ""
    private var activities: [String] = []
    /// A tag for this process. A resumed transcript still holds the entries
    /// of earlier runs, whose turns counted from one as well: without this
    /// a new reply would REPLACE an old entry instead of joining the end.
    private let run = String((0..<6).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
    private var entryID: String { "codex-\(run)-\(turn)" + (segment == 0 ? "" : "#\(segment)") }

    /// - Parameter resume: the thread id to pick up (an unarchived session).
    public init(cwd: String, skipPermissions: Bool, resume: String? = nil) {
        self.cwd = cwd
        self.skipPermissions = skipPermissions
        self.threadID = resume
    }

    public func send(_ text: String) throws {
        try queue.sync {
            if process?.isRunning == true { process?.terminate() }
            guard let tool = ToolPath.resolve("codex") else { throw AgentProcessError.toolMissing("codex") }
            turn += 1
            segment = 0
            turnText = ""
            activities = []
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            var args = ["exec"]
            if let threadID { args += ["resume"] }
            args += ["--json", "--skip-git-repo-check"]
            if threadID == nil { args += ["-C", (cwd as NSString).expandingTildeInPath] }
            // Manual permissions are Codex's own sandbox. It goes through
            // `-c` rather than `-s`: only `exec` takes the flag, and a
            // resumed turn ("exec resume") would be rejected outright —
            // which is what made a manual-mode session unresumable.
            args += skipPermissions
                ? ["--dangerously-bypass-approvals-and-sandbox"]
                : ["-c", "sandbox_mode=\"workspace-write\""]
            if let model, !model.isEmpty { args += ["-m", model] }
            if let effort, !effort.isEmpty { args += ["-c", "model_reasoning_effort=\"\(effort)\""] }
            if let threadID { args += [threadID] }
            args += ["-"]
            p.arguments = args
            p.currentDirectoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath)
            p.environment = ToolPath.environment()
            // The agent is told which session it is, so it can name itself
            // when it asks the server to restart (VISOR_SESSION).
            for (key, value) in approvalEnvironment { p.environment?[key] = value }
            let input = Pipe(), output = Pipe(), errors = Pipe()
            p.standardInput = input
            p.standardOutput = output
            p.standardError = errors
            reader = LineReader(handle: output.fileHandleForReading) { [weak self] line in self?.handle(line) }
            stderrReader = LineReader(handle: errors.fileHandleForReading) { [weak self] line in
                if line.contains("ERROR") { self?.onEvent?(.failure(line)) }
            }
            p.terminationHandler = { [weak self] proc in
                guard let self else { return }
                self.queue.async {
                    if self.process === proc { self.process = nil }
                    self.finishTurn()
                }
            }
            do { try p.run() } catch { throw AgentProcessError.spawnFailed("\(error)") }
            process = p
            input.fileHandleForWriting.write(text.data(using: .utf8)!)
            try? input.fileHandleForWriting.close()
            onEvent?(.busy(true))
            onEvent?(.activity("Thinking…"))
        }
    }

    public var processID: Int32? { queue.sync { process?.processIdentifier } }

    /// Ends the agent and waits for it. A quitting app must not return
    /// from this while the agent is alive: the moment we exit it is
    /// reparented to launchd, still running, writing into a pipe whose
    /// reader is gone — and the next launch, seeing an unfinished turn,
    /// starts a SECOND agent on the same session.
    public func stopAndWait(deadline: TimeInterval) {
        let running: Process? = queue.sync {
            guard let p = process else { return nil }
            // Codex reads its prompt up front; the turn in flight is interrupted.
            p.interrupt()
            process = nil
            return p
        }
        guard let running, running.isRunning else { return }
        let grace = Date().addingTimeInterval(max(0, deadline - 1))
        while running.isRunning && Date() < grace { usleep(50_000) }
        if running.isRunning { running.terminate() }
        let limit = Date().addingTimeInterval(1)
        while running.isRunning && Date() < limit { usleep(50_000) }
        if running.isRunning {
            kill(running.processIdentifier, SIGKILL)
            running.waitUntilExit()
        }
        finishTurn()
    }

    public func stop() {
        queue.sync {
            guard let running = process else { return }
            process = nil
            // Codex reads its whole prompt up front; a turn in flight is
            // interrupted (SIGINT, then SIGTERM if it lingers).
            running.interrupt()
            queue.asyncAfter(deadline: .now() + 2) {
                if running.isRunning { running.terminate() }
            }
            finishTurn()
        }
    }

    /// Codex records the turn's token usage in its rollout; read it back.
    private func reportContext() {
        guard let threadID else { return }
        if let context = SessionCatalog.codexContext(id: threadID) {
            onEvent?(.context(used: context.used, limit: context.limit))
        }
    }

    private func finishTurn() {
        if !turnText.isEmpty || !activities.isEmpty {
            onEvent?(.entry(TranscriptEntry(id: entryID, role: .assistant, text: turnText, activities: activities)))
        }
        onEvent?(.activity(nil))
        onEvent?(.busy(false))
    }

    private func handle(_ line: String) {
        guard let object = JSON.object(line), let type = object["type"] as? String else { return }
        switch type {
        case "thread.started":
            if let id = object["thread_id"] as? String { threadID = id }
        case "item.started", "item.updated", "item.completed":
            guard let item = object["item"] as? [String: Any] else { return }
            let kind = item["type"] as? String ?? ""
            switch kind {
            case "agent_message":
                if let text = item["text"] as? String {
                    if !activities.isEmpty {
                        // Words after commands: close this entry, open the next.
                        onEvent?(.entry(TranscriptEntry(id: entryID, role: .assistant, text: turnText, activities: activities)))
                        segment += 1
                        turnText = ""
                        activities = []
                    }
                    turnText = turnText.isEmpty ? text : turnText + "\n\n" + text
                    onEvent?(.entry(TranscriptEntry(id: entryID, role: .assistant, text: turnText, activities: activities)))
                }
            case "reasoning":
                if type == "item.started" { onEvent?(.activity("Thinking…")) }
            case "command_execution":
                let command = (item["command"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
                let label = "Shell: " + (command.count > 80 ? String(command.prefix(80)) + "…" : command)
                if type == "item.started" {
                    activities.append(label)
                    onEvent?(.activity(label))
                } else if type == "item.completed" {
                    let output = item["aggregated_output"] as? String ?? ""
                    onEvent?(.entry(TranscriptEntry(id: "codex-\(run)-\(turn)-\(item["id"] as? String ?? UUID().uuidString)", role: .tool, text: String(output.prefix(400)), toolName: "tool_result")))
                    onEvent?(.activity("Thinking…"))
                }
            case "file_change":
                let paths = ((item["changes"] as? [[String: Any]]) ?? []).compactMap { $0["path"] as? String }
                let label = "Edit: " + (paths.first.map { ($0 as NSString).lastPathComponent } ?? "files") + (paths.count > 1 ? " +\(paths.count - 1)" : "")
                if type == "item.completed" { activities.append(label) }
                onEvent?(.activity(type == "item.completed" ? "Thinking…" : label))
            case "web_search":
                // The query is often known only once the search completes.
                let query = item["query"] as? String ?? ""
                let label = query.isEmpty ? "Search" : "Search: " + query.prefix(80)
                if type == "item.started" { activities.append(label); onEvent?(.activity(label)) }
                else if type == "item.completed", !query.isEmpty, let index = activities.lastIndex(where: { $0.hasPrefix("Search") }) { activities[index] = label }
            case "mcp_tool_call":
                let label = "\(item["server"] as? String ?? "mcp").\(item["tool"] as? String ?? "tool")"
                if type == "item.started" { activities.append(label); onEvent?(.activity(label)) }
            case "error":
                let message = Self.unwrapped(item["message"] as? String ?? "Codex reported an error")
                // Codex reports its own hook-trust notice as an error item;
                // it is a warning about the run, not a failed turn.
                if !message.contains("hook-trust") { onEvent?(.failure(message)) }
            default:
                break
            }
        case "turn.completed":
            finishTurn()
            reportContext()
        case "turn.failed":
            let message = (object["error"] as? [String: Any])?["message"] as? String ?? "The turn failed"
            onEvent?(.failure(Self.unwrapped(message)))
            finishTurn()
        case "error":
            // Followed by turn.failed carrying the same message; that one is shown.
            break
        default:
            break
        }
    }

    /// Codex often wraps the API's JSON error as the message; show its text.
    static func unwrapped(_ message: String) -> String {
        guard message.hasPrefix("{"), let object = JSON.object(message) else { return message }
        if let error = object["error"] as? [String: Any], let text = error["message"] as? String { return text }
        if let text = object["message"] as? String { return text }
        return message
    }
}
