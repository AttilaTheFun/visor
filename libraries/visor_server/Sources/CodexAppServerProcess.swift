// Codex through its own app-server: one long-lived `codex app-server`
// per session speaking newline-delimited JSON-RPC on stdio. A thread is
// started (or resumed by id), each message is a turn on it, and the
// turn's items — the agent's words, the commands it runs, the files it
// changes — arrive as notifications and become the transcript's rows.
// A turn is interrupted in place (turn/interrupt) and the thread stays
// up, so the next message carries straight on — which the older
// one-process-per-turn `codex exec` driver could not do.

import Foundation
import VisorProtocol

public final class CodexAppServerProcess: AgentProcess, @unchecked Sendable {
    public var onEvent: (@Sendable (AgentEvent) -> Void)?
    public var skipPermissions: Bool
    public var model: String?
    public var effort: String?
    public var onModel: (@Sendable (String) -> Void)?
    public var approvalEnvironment: [String: String] = [:]

    private let cwd: String
    private let queue = DispatchQueue(label: "visor.codex.appserver")
    private var process: Process?
    private var stdin: FileHandle?
    private var reader: LineReader?
    private var stderrReader: LineReader?
    private var threadID: String?
    private var turnID: String?
    private var nextRequestID = 1
    /// Answers waited on, by request id.
    private var replies: [Int: ([String: Any]) -> Void] = [:]
    /// The turn's agent messages so far, by item id, for the segment
    /// index each takes in the transcript.
    private var messageIndex: [String: Int] = [:]
    private var turnMessages = 0
    private var stopping = false

    public init(cwd: String, skipPermissions: Bool, resume: String?) {
        self.cwd = cwd
        self.skipPermissions = skipPermissions
        threadID = resume
    }

    public var resumeID: String? { queue.sync { threadID } }
    public var resumeCommand: String? {
        guard let id = resumeID else { return nil }
        return "cd \(ClaudeProcess.quoted(cwd)) && codex resume \(id)"
    }
    public var processID: Int32? { queue.sync { process?.processIdentifier } }

    // MARK: Turns

    public func send(_ text: String) throws {
        try queue.sync {
            if process == nil || process?.isRunning != true { try spawn() }
            onEvent?(.busy(true))
            onEvent?(.activity("Thinking…"))
            turnMessages = 0
            messageIndex = [:]
            let start: () -> Void = { [weak self] in
                guard let self, let threadID = self.threadID else { return }
                var params: [String: Any] = ["threadId": threadID, "input": [["type": "text", "text": text]]]
                if let model = self.model, !model.isEmpty { params["model"] = model }
                if let effort = self.effort, !effort.isEmpty { params["effort"] = effort }
                self.request("turn/start", params) { [weak self] reply in
                    guard let self else { return }
                    if let turn = (reply["result"] as? [String: Any])?["turn"] as? [String: Any], let id = turn["id"] as? String {
                        self.queue.async { self.turnID = id }
                    } else if let error = reply["error"] {
                        self.onEvent?(.failure("Codex: \(Self.describe(error))"))
                        self.onEvent?(.activity(nil))
                        self.onEvent?(.busy(false))
                    }
                }
            }
            if threadID == nil {
                // The first turn starts the thread; later ones ride on it.
                request("thread/start", threadParams()) { [weak self] reply in
                    guard let self else { return }
                    if let thread = (reply["result"] as? [String: Any])?["thread"] as? [String: Any], let id = thread["id"] as? String {
                        self.queue.async {
                            self.threadID = id
                            self.onEvent?(.session(id))
                            start()
                        }
                    } else {
                        self.onEvent?(.failure("Codex: \(Self.describe(reply["error"] ?? "could not start a thread"))"))
                        self.onEvent?(.busy(false))
                    }
                }
            } else {
                start()
            }
        }
    }

    /// Ends the turn in flight; the thread stays, and the next message
    /// carries on in it.
    public func interrupt() {
        queue.sync {
            guard let threadID, let turnID else { return }
            request("turn/interrupt", ["threadId": threadID, "turnId": turnID]) { _ in }
        }
    }

    public func stop() {
        queue.sync {
            guard let running = process else { return }
            stopping = true
            process = nil
            try? stdin?.close()
            stdin = nil
            queue.asyncAfter(deadline: .now() + 2) { if running.isRunning { running.terminate() } }
            onEvent?(.activity(nil))
            onEvent?(.busy(false))
        }
    }

    public func stopAndWait(deadline: TimeInterval) {
        let running: Process? = queue.sync {
            guard let p = process else { return nil }
            stopping = true
            process = nil
            try? stdin?.close()
            stdin = nil
            return p
        }
        guard let running, running.isRunning else { return }
        let grace = Date().addingTimeInterval(max(0, deadline - 1))
        while running.isRunning && Date() < grace { usleep(50_000) }
        if running.isRunning { running.terminate() }
        let limit = Date().addingTimeInterval(1)
        while running.isRunning && Date() < limit { usleep(50_000) }
        if running.isRunning { kill(running.processIdentifier, SIGKILL); running.waitUntilExit() }
    }

    // MARK: The daemon

    /// Auto: no prompts, no sandbox. Manual: Codex's own workspace
    /// sandbox, no prompts — the same two shapes the exec driver used, so
    /// nothing asks a question over this channel.
    private func threadParams() -> [String: Any] {
        var params: [String: Any] = [
            "cwd": (cwd as NSString).expandingTildeInPath,
            "approvalPolicy": "never",
            "sandbox": skipPermissions ? "danger-full-access" : "workspace-write",
        ]
        if let model, !model.isEmpty { params["model"] = model }
        return params
    }

    private func spawn() throws {
        guard let executable = ToolPath.resolve("codex") else { throw AgentProcessError.toolMissing("codex") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["app-server"]
        p.currentDirectoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath)
        p.environment = ToolPath.environment()
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
                if self.process === proc { self.process = nil; self.stdin = nil }
                let expected = self.stopping
                self.stopping = false
                if !expected {
                    self.onEvent?(.failure("Codex's app server exited (status \(proc.terminationStatus))."))
                    self.onEvent?(.activity(nil))
                    self.onEvent?(.busy(false))
                }
            }
        }
        do { try p.run() } catch { throw AgentProcessError.spawnFailed("\(error)") }
        process = p
        stdin = input.fileHandleForWriting
        request("initialize", ["clientInfo": ["name": "visor", "version": "1"]]) { _ in }
        // A thread being resumed is picked up now, so the first turn does
        // not wait on it.
        if let threadID {
            var params = threadParams()
            params["threadId"] = threadID
            request("thread/resume", params) { [weak self] reply in
                if let error = reply["error"] { self?.onEvent?(.failure("Codex could not resume the thread: \(Self.describe(error))")) }
            }
        }
    }

    /// Sends a request; `then` runs with the reply object (result or error).
    private func request(_ method: String, _ params: [String: Any], then: @escaping ([String: Any]) -> Void) {
        let id = nextRequestID
        nextRequestID += 1
        replies[id] = then
        let object: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        stdin?.write(data)
        stdin?.write("\n".data(using: .utf8)!)
    }

    private func handle(_ line: String) {
        guard let object = JSON.object(line) else { return }
        // A reply to something asked.
        if let id = object["id"] as? Int, object["method"] == nil {
            queue.async {
                if let then = self.replies.removeValue(forKey: id) { then(object) }
            }
            return
        }
        guard let method = object["method"] as? String else { return }
        let params = object["params"] as? [String: Any] ?? [:]
        // The server asking us something (an approval) — not expected
        // with prompts off; answered no rather than left hanging.
        if let id = object["id"] as? Int {
            let answer: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": ["decision": "denied"]]
            if let data = try? JSONSerialization.data(withJSONObject: answer) { stdin?.write(data); stdin?.write("\n".data(using: .utf8)!) }
            onEvent?(.activity("Declined: \(method)"))
            return
        }
        switch method {
        case "item/agentMessage/delta":
            guard let itemID = params["itemId"] as? String, let delta = params["delta"] as? String else { return }
            onEvent?(.delta(message: itemID, text: delta))
        case "item/started":
            guard let item = params["item"] as? [String: Any] else { return }
            let id = item["id"] as? String ?? UUID().uuidString
            switch item["type"] as? String {
            case "commandExecution":
                let label = "Bash: \(Self.short(item["command"] as? String ?? "command"))"
                onEvent?(.activity(label))
                onEvent?(.toolStarted(id: id, name: "Bash", label: label, tasks: nil))
            case "fileChange":
                let label = "Edit: \(Self.changeSummary(item))"
                onEvent?(.activity(label))
                onEvent?(.toolStarted(id: id, name: "Edit", label: label, tasks: nil))
            case "mcpToolCall":
                let name = item["tool"] as? String ?? "tool"
                let label = "\(name): \(Self.short(JSON.summary(item["arguments"])))"
                onEvent?(.activity(label))
                onEvent?(.toolStarted(id: id, name: name, label: label, tasks: nil))
            case "reasoning":
                onEvent?(.activity("Thinking…"))
                onEvent?(.thinking(true))
            default: break
            }
        case "item/completed":
            guard let item = params["item"] as? [String: Any], let id = item["id"] as? String else { return }
            onEvent?(.toolFinished(id: id))
            switch item["type"] as? String {
            case "reasoning":
                onEvent?(.thinking(false))
            case "agentMessage":
                // The finished message, under the id its deltas carried,
                // so a client's streamed row settles into this one.
                guard let text = item["text"] as? String, !text.isEmpty else { return }
                onEvent?(.entry(TranscriptEntry(id: id, role: .assistant, text: text)))
            case "commandExecution":
                let output = item["aggregatedOutput"] as? String ?? ""
                let command = Self.short(item["command"] as? String ?? "command")
                onEvent?(.entry(TranscriptEntry(id: "codex-tool-" + id, role: .tool,
                                                text: String(output.prefix(400)), activities: [command], toolName: "Bash")))
            case "fileChange":
                onEvent?(.entry(TranscriptEntry(id: "codex-tool-" + id, role: .tool, text: Self.changeSummary(item), toolName: "Edit")))
            case "mcpToolCall":
                let result = JSON.summary(item["result"], limit: 400)
                onEvent?(.entry(TranscriptEntry(id: "codex-tool-" + id, role: .tool, text: result,
                                                toolName: item["tool"] as? String ?? "tool")))
            default: break
            }
        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            if let error = turn["error"] as? [String: Any], let message = error["message"] as? String, !message.isEmpty,
               (turn["status"] as? String) != "interrupted" {
                onEvent?(.failure(message))
            }
            queue.async { self.turnID = nil }
            onEvent?(.activity(nil))
            onEvent?(.busy(false))
        case "thread/tokenUsage/updated":
            if let usage = params["tokenUsage"] as? [String: Any] ?? params["usage"] as? [String: Any] {
                let used = (usage["total"] as? Int) ?? (usage["totalTokens"] as? Int) ?? (usage["inputTokens"] as? Int ?? 0)
                let limit = usage["contextWindow"] as? Int ?? usage["modelContextWindow"] as? Int
                if used > 0 { onEvent?(.context(used: used, limit: limit)) }
            }
        case "error":
            if let message = (params["error"] as? [String: Any])?["message"] as? String ?? params["message"] as? String {
                onEvent?(.failure(message))
            }
        default:
            break
        }
    }

    private static func short(_ text: String, limit: Int = 80) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    private static func changeSummary(_ item: [String: Any]) -> String {
        let changes = item["changes"] as? [[String: Any]] ?? []
        let paths = changes.compactMap { $0["path"] as? String }
        return paths.isEmpty ? "files" : paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
    }

    private static func describe(_ error: Any) -> String {
        if let object = error as? [String: Any], let message = object["message"] as? String { return message }
        return "\(error)"
    }
}
