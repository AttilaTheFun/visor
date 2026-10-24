// Codex through its own app-server: one long-lived `codex app-server`
// per session speaking newline-delimited JSON-RPC on stdio. A thread is
// started (or resumed by id), each message is a turn on it, and the
// turn's items — the agent's words, the commands it runs, the files it
// changes — arrive as notifications; their rows come from the rollout
// the server follows. A turn is interrupted in place (turn/interrupt) and
// the thread stays up, so the next message carries straight on.

import Foundation
import VisorProtocol

@MainActor
public final class CodexAppServerProcess: AgentProcess, HostableProcess {
    /// The answer to a request: what it names, or what went wrong. A
    /// request whose app server went away is answered with that.
    struct Reply {
        var thread: String?
        var turn: String?
        var error: String?
        /// For a goal's requests: the goal (nil inside when there is none).
        var goal: CodexGoal??
    }

    public let events: AsyncStream<AgentEvent>
    let emit: AsyncStream<AgentEvent>.Continuation
    public var skipPermissions: Bool
    public var model: String?
    public var effort: String?
    public var approvalEnvironment: [String: String] = [:]
    /// Where its agent runs when that is a container here.
    var container: ContainerPlacement?

    private let cwd: String
    /// The running app server. One that was stopped is no longer this, and
    /// what it still says is not passed on.
    private var child: (any AgentChild)?
    var threadID: String?
    private var turnID: String?
    /// A turn asked for whose id has not come back: an interrupt asked for
    /// now is sent once it has (`turn/interrupt` names the turn).
    private var turnStarting = false
    private var stopWhenStarted = false
    private var nextRequestID = 1
    /// Answers waited on, by request id.
    private var replies: [Int: CheckedContinuation<Reply, Never>] = [:]
    /// The account's limits as last said, for a sparse update to lay
    /// itself over.
    private var rateLimits: CodexOutput.RateLimits?
    /// Questions Codex asked the user and waits on, by the request shown:
    /// the app server's request id, and each question's id by its words.
    private var questionsAsked: [String: (rpc: Int, ids: [String: String])] = [:]
    /// The agent's messages whose words have been streamed, by item id,
    /// until each completes: one sent only whole is shown then.
    private var streamedItems: Set<String> = []

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

    func running() -> (any AgentChild)? {
        guard let child, child.isRunning else { return nil }
        return child
    }

    var hostedChild: HostedChild? { running() as? HostedChild }
    /// The turn in flight, which an interrupt names.
    var carried: [String: String] { turnID.map { ["turn": $0] } ?? [:] }

    /// An app server left running by an earlier launch: already started,
    /// its thread already resumed, so only heard from here on. Its
    /// requests are numbered apart from the earlier launch's, whose
    /// answers may still come.
    func adopt(_ child: any AgentChild, carried: [String: String]) {
        self.child = child
        turnID = carried["turn"]
        nextRequestID = Int.random(in: 1_000_000...1_000_000_000)
        follow(child)
    }

    // MARK: Turns

    public func startsTurn(_ text: String) -> Bool { CodexCommand(text) == nil }

    public func send(_ text: String) throws {
        let child = try running() ?? spawn()
        // Codex's own commands are requests of its app server, not words
        // for the model (CodexAppServerProcess+Commands.swift).
        if let command = CodexCommand(text) {
            Task { await self.perform(command, on: child) }
            return
        }
        emit.yield(.busy(true))
        emit.yield(.activity("Thinking…"))
        turnStarting = true
        Task { await self.turn(text, on: child) }
    }

    public func start() throws { _ = try running() ?? spawn() }

    /// Starts the turn: on the thread there is, or on one started for it.
    private func turn(_ text: String, on child: any AgentChild) async {
        guard let threadID = await thread(on: child) else {
            turnStarting = false
            stopWhenStarted = false
            emit.yield(.busy(false))
            return
        }
        var params: [String: Any] = ["threadId": threadID, "input": [["type": "text", "text": text]]]
        if let model, !model.isEmpty { params["model"] = model }
        if let effort, !effort.isEmpty { params["effort"] = effort }
        let reply = await request("turn/start", params, of: child)
        guard self.child === child else { return }
        turnStarting = false
        if let id = reply.turn {
            turnID = id
            if stopWhenStarted { interrupt() }
        } else if let error = reply.error {
            stopWhenStarted = false
            emit.yield(.failure("Codex: \(error)"))
            emit.yield(.activity(nil))
            emit.yield(.busy(false))
        }
    }

    /// The thread there is, or one started now: the first turn (or a goal
    /// set before any) starts it, and later ones ride on it. Nil, said as
    /// a failure, when it cannot be started.
    func thread(on child: any AgentChild) async -> String? {
        if let threadID { return threadID }
        let reply = await request("thread/start", threadParams(), of: child)
        guard self.child === child else { return nil }
        guard let id = reply.thread else {
            emit.yield(.failure("Codex: \(reply.error ?? "could not start a thread")"))
            return nil
        }
        threadID = id
        emit.yield(.session(id))
        return id
    }

    /// Ends the turn in flight; the thread stays, and the next message
    /// carries on in it.
    public func interrupt() {
        if turnStarting, turnID == nil {
            stopWhenStarted = true
            return
        }
        stopWhenStarted = false
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
    private func release() -> (any AgentChild)? {
        guard let child else { return nil }
        self.child = nil
        turnID = nil
        turnStarting = false
        stopWhenStarted = false
        abandonRequests()
        emit.yield(.activity(nil))
        emit.yield(.memory(nil))
        emit.yield(.busy(false))
        return child
    }

    private func abandonRequests() {
        let waiting = replies
        replies = [:]
        for continuation in waiting.values { continuation.resume(returning: Reply(error: "Codex's app server is gone")) }
    }

    /// Codex's questions to the user (request_user_input), which it offers
    /// outside plan mode only with this feature, under development in Codex
    /// 0.162; its warning about that is not the user's to read.
    static let questionArguments = ["-c", "features.default_mode_request_user_input=true", "-c", "suppress_unstable_features_warning=true"]

    public func answer(_ request: String, with answers: [String: String]?) {
        guard let asked = questionsAsked.removeValue(forKey: request), let child else { return }
        // By each question's id; none at all when the user would not answer.
        var byID: [String: Any] = [:]
        for (words, answer) in answers ?? [:] {
            guard let id = asked.ids[words] else { continue }
            byID[id] = ["answers": [answer]]
        }
        child.write(["jsonrpc": "2.0", "id": asked.rpc, "result": ["answers": byID]])
    }

    // MARK: The daemon

    /// Auto: no prompts, no sandbox. Manual: Codex's own workspace
    /// sandbox, no prompts — so nothing asks a question over this channel.
    private func threadParams() -> [String: Any] {
        var params: [String: Any] = [
            "cwd": HostFolders.resolve(cwd),
            "approvalPolicy": "never",
            "sandbox": skipPermissions ? "danger-full-access" : "workspace-write",
        ]
        if let model, !model.isEmpty { params["model"] = model }
        return params
    }

    func spawn() throws -> any AgentChild {
        // In a container: codex by its name on the container's path.
        let executable: String
        if container != nil {
            executable = "codex"
        } else {
            guard let found = ToolPath.resolve("codex") else { throw AgentProcessError.toolMissing("codex") }
            executable = found
        }
        let environment = container.map { approvalEnvironment.merging(["VISOR_URL": $0.serverURL]) { _, ours in ours } }
            ?? ToolPath.environment().merging(approvalEnvironment) { _, ours in ours }
        // Visor's MCP server: the other sessions.
        let child = try AgentChildren.start(executable: executable,
                                            arguments: ["app-server"] + Self.questionArguments + VisorMCP.codexArguments(approvalEnvironment, container: container),
                                            directory: HostFolders.resolve(cwd),
                                            environment: environment,
                                            session: approvalEnvironment["VISOR_SESSION"], container: container)
        self.child = child
        follow(child)
        Task {
            // Codex's questions to the user are among its experimental
            // requests: asked for (with the feature, in `arguments`).
            _ = await self.request("initialize", ["clientInfo": ["name": "visor", "version": "1"], "capabilities": ["experimentalApi": true]],
                                   of: child)
            // How the account is paid for and how near its limits it is;
            // turns update the limits as they go.
            _ = await self.request("account/read", [:], of: child)
            _ = await self.request("account/rateLimits/read", ["excludeResetCreditDetails": true], of: child)
        }
        // A thread being resumed is picked up now, so the first turn does
        // not wait on it.
        if let threadID {
            Task {
                // Made in the task, so what is sent to the request is its
                // own (Swift 6.2 will not send a captured variable).
                var params = self.threadParams()
                params["threadId"] = threadID
                let reply = await self.request("thread/resume", params, of: child)
                if let error = reply.error, self.child === child {
                    self.emit.yield(.failure("Codex could not resume the thread: \(error)"))
                }
                // The goal as it stands now: it may have been met, or
                // cleared, while no one was following.
                _ = await self.request("thread/goal/get", ["threadId": threadID], of: child)
            }
        }
        return child
    }

    /// Hears the app server: everything it says, in order, and then that
    /// it is gone.
    private func follow(_ child: any AgentChild) {
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
            self.emit.yield(.memory(nil))
            self.emit.yield(.busy(false))
        }
        Task { [weak self] in
            for await line in child.errors.lines({ $0.contains("ERROR") ? [$0] : [] }) {
                guard let self else { return }
                if self.child === child { self.emit.yield(.failure(line)) }
            }
        }
        Task { [weak self] in
            for await notice in child.notices {
                guard let self else { return }
                if self.child === child { self.emit.yield(.notice(notice)) }
            }
        }
        (child as? HostedChild)?.onMemory = { [weak self] bytes in
            if let self, self.child === child { self.emit.yield(.memory(Int64(clamping: bytes))) }
        }
    }

    /// Asks the app server something and waits for its answer.
    func request(_ method: String, _ params: sending [String: Any], of child: any AgentChild) async -> Reply {
        guard self.child === child else { return Reply(error: "Codex's app server is gone") }
        let id = nextRequestID
        nextRequestID += 1
        child.write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        return await withCheckedContinuation { replies[id] = $0 }
    }

    /// The agent's words for a message: a piece as it streams, or the
    /// whole as the message completes — shown only if none of it streamed,
    /// so a streamed message is not shown twice.
    func say(item: String, text: String, whole: Bool) {
        if whole {
            guard streamedItems.remove(item) == nil, !text.isEmpty else { return }
        } else {
            streamedItems.insert(item)
        }
        emit.yield(.delta(message: item, text: text))
    }

    private func take(_ output: CodexOutput, from child: any AgentChild) {
        switch output {
        case .reply(let id, let thread, let turn, let error, let goal):
            replies.removeValue(forKey: id)?.resume(returning: Reply(thread: thread, turn: turn, error: error, goal: goal))
        case .turnStarted(let id):
            // One Codex started itself (its goal's next turn, a review)
            // is followed as one asked for.
            guard turnID != id else { return }
            turnID = id
            turnStarting = false
            if stopWhenStarted { interrupt() }
            emit.yield(.busy(true))
            emit.yield(.activity("Thinking…"))
        case .goal(let goal):
            emit.yield(.goal(goal.flatMap { $0.met ? nil : $0.objective }, met: goal?.met ?? false))
        case .questions(let id, let asked):
            // Shown to the user as the session's waiting question; the
            // answers go back under each question's id (`answer`).
            let request = "codex-\(id)"
            questionsAsked[request] = (id, Dictionary(asked.map { ($0.question.question, $0.id) }, uniquingKeysWith: { first, _ in first }))
            emit.yield(.question(ApprovalRequest(id: request, tool: "request_user_input", summary: asked.first?.question.question ?? "",
                                                 questions: asked.map(\.question))))
        case .asked(let id, let method):
            // Not expected with prompts off; answered no rather than left
            // hanging.
            child.write(["jsonrpc": "2.0", "id": id, "result": ["decision": "denied"]])
            emit.yield(.activity("Declined: \(method)"))
        case .text(let item, let text):
            say(item: item, text: text, whole: false)
        case .messageCompleted(let item, let text):
            say(item: item, text: text, whole: true)
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
            // A question the turn asked waits no longer.
            questionsAsked = [:]
            streamedItems = []
            turnID = nil
            turnStarting = false
            stopWhenStarted = false
            emit.yield(.activity(nil))
            emit.yield(.busy(false))
        case .tokens(let used, let limit):
            emit.yield(.context(used: used, limit: limit))
        case .spent(let usage):
            emit.yield(.spent(usage))
        case .plan(let plan, let subscription):
            emit.yield(.plan(plan, subscription: subscription))
        case .rateLimits(let update):
            let merged = update.merged(over: rateLimits)
            rateLimits = merged
            emit.yield(.limits(merged.limits))
        case .failure(let message):
            emit.yield(.failure(message))
        }
    }
}
