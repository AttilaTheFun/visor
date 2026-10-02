// Codex through its own app-server: one long-lived `codex app-server`
// per session speaking newline-delimited JSON-RPC on stdio. A thread is
// started (or resumed by id), each message is a turn on it, and the
// turn's items — the agent's words, the commands it runs, the files it
// changes — arrive as notifications; their rows come from the rollout
// the server follows. A turn is interrupted in place (turn/interrupt) and
// the thread stays up, so the next message carries straight on.

import Foundation
import VisorProtocol

/// What a line from the app server says, as far as the server cares: read
/// off the main actor.
enum CodexOutput: Sendable {
    /// The answer to a request of ours: the thread or turn it names, or
    /// what went wrong.
    case reply(id: Int, thread: String?, turn: String?, error: String?)
    /// The app server asking us something (an approval).
    case asked(id: Int, method: String)
    case text(item: String, String)
    case toolStarted(id: String, name: String, label: String)
    case reasoningStarted
    case itemCompleted(id: String, reasoning: Bool)
    /// The turn ended; with what went wrong, unless it was interrupted.
    case turnCompleted(failure: String?)
    case tokens(used: Int, limit: Int?)
    case failure(String)

    static func parse(_ line: String) -> [CodexOutput] {
        guard let object = JSON.object(line) else { return [] }
        if let id = object["id"] as? Int, object["method"] == nil {
            let result = object["result"] as? [String: Any]
            return [.reply(id: id, thread: (result?["thread"] as? [String: Any])?["id"] as? String,
                           turn: (result?["turn"] as? [String: Any])?["id"] as? String,
                           error: object["error"].map(describe))]
        }
        guard let method = object["method"] as? String else { return [] }
        if let id = object["id"] as? Int { return [.asked(id: id, method: method)] }
        let params = object["params"] as? [String: Any] ?? [:]
        switch method {
        case "item/agentMessage/delta":
            guard let item = params["itemId"] as? String, let delta = params["delta"] as? String else { return [] }
            return [.text(item: item, delta)]
        case "item/started":
            guard let item = params["item"] as? [String: Any] else { return [] }
            let id = item["id"] as? String ?? UUID().uuidString
            switch item["type"] as? String {
            case "commandExecution":
                return [.toolStarted(id: id, name: "Bash", label: "Bash: \(short(item["command"] as? String ?? "command"))")]
            case "fileChange":
                return [.toolStarted(id: id, name: "Edit", label: "Edit: \(changeSummary(item))")]
            case "mcpToolCall":
                let name = item["tool"] as? String ?? "tool"
                return [.toolStarted(id: id, name: name, label: "\(name): \(short(JSON.summary(item["arguments"])))")]
            case "reasoning":
                return [.reasoningStarted]
            default:
                return []
            }
        case "item/completed":
            guard let item = params["item"] as? [String: Any], let id = item["id"] as? String else { return [] }
            return [.itemCompleted(id: id, reasoning: item["type"] as? String == "reasoning")]
        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            var failure: String?
            if let error = turn["error"] as? [String: Any], let message = error["message"] as? String, !message.isEmpty,
               (turn["status"] as? String) != "interrupted" {
                failure = message
            }
            return [.turnCompleted(failure: failure)]
        case "thread/tokenUsage/updated":
            guard let usage = params["tokenUsage"] as? [String: Any] ?? params["usage"] as? [String: Any] else { return [] }
            let used = (usage["total"] as? Int) ?? (usage["totalTokens"] as? Int) ?? (usage["inputTokens"] as? Int ?? 0)
            return used > 0 ? [.tokens(used: used, limit: usage["contextWindow"] as? Int ?? usage["modelContextWindow"] as? Int)] : []
        case "error":
            guard let message = (params["error"] as? [String: Any])?["message"] as? String ?? params["message"] as? String else { return [] }
            return [.failure(message)]
        default:
            return []
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

@MainActor
public final class CodexAppServerProcess: AgentProcess {
    /// The answer to a request: what it names, or what went wrong. A
    /// request whose app server went away is answered with that.
    private struct Reply {
        var thread: String?
        var turn: String?
        var error: String?
    }

    public let events: AsyncStream<AgentEvent>
    private let emit: AsyncStream<AgentEvent>.Continuation
    public var skipPermissions: Bool
    public var model: String?
    public var effort: String?
    public var approvalEnvironment: [String: String] = [:]

    private let cwd: String
    /// The running app server. One that was stopped is no longer this, and
    /// what it still says is not passed on.
    private var child: PipedChild?
    private var threadID: String?
    private var turnID: String?
    private var nextRequestID = 1
    /// Answers waited on, by request id.
    private var replies: [Int: CheckedContinuation<Reply, Never>] = [:]

    public init(cwd: String, skipPermissions: Bool, resume: String?) {
        self.cwd = cwd
        self.skipPermissions = skipPermissions
        threadID = resume
        (events, emit) = AsyncStream.makeStream()
    }

    public var resumeID: String? { threadID }
    public var resumeCommand: String? {
        guard let id = resumeID else { return nil }
        return "cd \(ClaudeProcess.quoted(cwd)) && codex resume \(id)"
    }
    public var processID: Int32? { running()?.pid }

    private func running() -> PipedChild? {
        guard let child, child.isRunning else { return nil }
        return child
    }

    // MARK: Turns

    public func send(_ text: String) throws {
        let child = try running() ?? spawn()
        emit.yield(.busy(true))
        emit.yield(.activity("Thinking…"))
        Task { await self.turn(text, on: child) }
    }

    /// Starts the turn: on the thread there is, or on one started for it.
    private func turn(_ text: String, on child: PipedChild) async {
        if threadID == nil {
            // The first turn starts the thread; later ones ride on it.
            let reply = await request("thread/start", threadParams(), of: child)
            guard self.child === child else { return }
            guard let id = reply.thread else {
                emit.yield(.failure("Codex: \(reply.error ?? "could not start a thread")"))
                emit.yield(.busy(false))
                return
            }
            threadID = id
            emit.yield(.session(id))
        }
        guard let threadID else { return }
        var params: [String: Any] = ["threadId": threadID, "input": [["type": "text", "text": text]]]
        if let model, !model.isEmpty { params["model"] = model }
        if let effort, !effort.isEmpty { params["effort"] = effort }
        let reply = await request("turn/start", params, of: child)
        guard self.child === child else { return }
        if let id = reply.turn {
            turnID = id
        } else if let error = reply.error {
            emit.yield(.failure("Codex: \(error)"))
            emit.yield(.activity(nil))
            emit.yield(.busy(false))
        }
    }

    /// Ends the turn in flight; the thread stays, and the next message
    /// carries on in it.
    public func interrupt() {
        guard let child = running(), let threadID, let turnID else { return }
        Task { _ = await self.request("turn/interrupt", ["threadId": threadID, "turnId": turnID], of: child) }
    }

    public func stop() {
        guard let child = release() else { return }
        Task { await child.end(grace: .seconds(2)) }
    }

    public func end(within deadline: Duration) async {
        guard let child = release() else { return }
        await child.end(grace: max(.zero, deadline - .seconds(1)))
    }

    /// Lets go of the running app server, for whoever is ending it: from
    /// here the session is idle, and nothing asked of it will be answered.
    private func release() -> PipedChild? {
        guard let child else { return nil }
        self.child = nil
        turnID = nil
        abandonRequests()
        emit.yield(.activity(nil))
        emit.yield(.busy(false))
        return child
    }

    private func abandonRequests() {
        let waiting = replies
        replies = [:]
        for continuation in waiting.values { continuation.resume(returning: Reply(error: "Codex's app server is gone")) }
    }

    // MARK: The daemon

    /// Auto: no prompts, no sandbox. Manual: Codex's own workspace
    /// sandbox, no prompts — so nothing asks a question over this channel.
    private func threadParams() -> [String: Any] {
        var params: [String: Any] = [
            "cwd": (cwd as NSString).expandingTildeInPath,
            "approvalPolicy": "never",
            "sandbox": skipPermissions ? "danger-full-access" : "workspace-write",
        ]
        if let model, !model.isEmpty { params["model"] = model }
        return params
    }

    private func spawn() throws -> PipedChild {
        guard let executable = ToolPath.resolve("codex") else { throw AgentProcessError.toolMissing("codex") }
        // Visor's MCP server: the other sessions.
        let child = try PipedChild(executable: executable, arguments: ["app-server"] + VisorMCP.codexArguments(approvalEnvironment),
                                   directory: (cwd as NSString).expandingTildeInPath,
                                   environment: ToolPath.environment().merging(approvalEnvironment) { _, ours in ours })
        self.child = child
        // Everything it says, in order, and then that it is gone.
        Task { [weak self] in
            for await output in child.output.lines({ CodexOutput.parse($0) }) {
                guard let self else { return }
                if self.child === child { self.take(output, from: child) }
            }
            let exit = await child.exit.value
            guard let self, self.child === child else { return }
            self.child = nil
            self.turnID = nil
            self.abandonRequests()
            self.emit.yield(.failure("Codex's app server exited (status \(exit.status))."))
            self.emit.yield(.activity(nil))
            self.emit.yield(.busy(false))
        }
        Task { [weak self] in
            for await line in child.errors.lines({ $0.contains("ERROR") ? [$0] : [] }) {
                guard let self else { return }
                if self.child === child { self.emit.yield(.failure(line)) }
            }
        }
        Task {
            _ = await self.request("initialize", ["clientInfo": ["name": "visor", "version": "1"]], of: child)
        }
        // A thread being resumed is picked up now, so the first turn does
        // not wait on it.
        if let threadID {
            var params = threadParams()
            params["threadId"] = threadID
            Task {
                let reply = await self.request("thread/resume", params, of: child)
                if let error = reply.error, self.child === child {
                    self.emit.yield(.failure("Codex could not resume the thread: \(error)"))
                }
            }
        }
        return child
    }

    /// Asks the app server something and waits for its answer.
    private func request(_ method: String, _ params: sending [String: Any], of child: PipedChild) async -> Reply {
        guard self.child === child else { return Reply(error: "Codex's app server is gone") }
        let id = nextRequestID
        nextRequestID += 1
        child.write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        return await withCheckedContinuation { replies[id] = $0 }
    }

    private func take(_ output: CodexOutput, from child: PipedChild) {
        switch output {
        case .reply(let id, let thread, let turn, let error):
            replies.removeValue(forKey: id)?.resume(returning: Reply(thread: thread, turn: turn, error: error))
        case .asked(let id, let method):
            // Not expected with prompts off; answered no rather than left
            // hanging.
            child.write(["jsonrpc": "2.0", "id": id, "result": ["decision": "denied"]])
            emit.yield(.activity("Declined: \(method)"))
        case .text(let item, let text):
            emit.yield(.delta(message: item, text: text))
        case .toolStarted(let id, let name, let label):
            emit.yield(.activity(label))
            emit.yield(.toolStarted(id: id, name: name, label: label, tasks: nil))
        case .reasoningStarted:
            emit.yield(.activity("Thinking…"))
            emit.yield(.thinking(true))
        case .itemCompleted(let id, let reasoning):
            emit.yield(.toolFinished(id: id))
            if reasoning { emit.yield(.thinking(false)) }
        case .turnCompleted(let failure):
            if let failure { emit.yield(.failure(failure)) }
            turnID = nil
            emit.yield(.activity(nil))
            emit.yield(.busy(false))
        case .tokens(let used, let limit):
            emit.yield(.context(used: used, limit: limit))
        case .failure(let message):
            emit.yield(.failure(message))
        }
    }
}
