// Claude Code as a session: one `claude -p` process with stream-json on
// both ends, fed a user message per turn on stdin, kept alive between
// turns. A stopped (or exited) process is resumed by its session id on the
// next turn, so the conversation is never lost.
//
// The output stream (with --include-partial-messages):
//   {"type":"system","subtype":"init","session_id":…}
//   {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":…}}}
//   {"type":"assistant","message":{"id":…,"content":[{"type":"text"|"tool_use"|"thinking",…}]}}
//   {"type":"user","message":{"content":[{"type":"tool_result",…}]}}
//   {"type":"result","is_error":…,"result":…}

import Foundation
import VisorProtocol

@MainActor
public final class ClaudeProcess: AgentProcess {
    public let events: AsyncStream<AgentEvent>
    private let emit: AsyncStream<AgentEvent>.Continuation

    private let cwd: String
    /// "claude", or another CLI speaking the same stream-json protocol ("ori").
    private let tool: String
    public var skipPermissions: Bool
    public var model: String?
    public var effort: String?
    public var approvalEnvironment: [String: String] = [:]
    /// The running agent. One that was stopped is no longer this, and what
    /// it still says is not passed on.
    private var child: PipedChild?
    public private(set) var resumeID: String?
    public var resumeCommand: String? {
        guard let id = resumeID else { return nil }
        return "cd \(ClaudeProcess.quoted(cwd)) && \(tool) --resume \(id)"
    }
    private var counter = 0
    /// Set by `interrupt()`: the error result that follows is the turn
    /// ending on request, not a failure to show.
    private var interrupting = false
    /// The id of the assistant message whose words are streaming now,
    /// from its message_start; each delta is named with it.
    private var streamingMessageID = ""
    private var streamCounter = 0

    /// - Parameter resume: the session id to pick up (an unarchived session).
    public init(cwd: String, skipPermissions: Bool, resume: String? = nil, tool: String = "claude") {
        self.cwd = cwd
        self.skipPermissions = skipPermissions
        self.resumeID = resume
        self.tool = tool
        (events, emit) = AsyncStream.makeStream()
    }

    static func quoted(_ path: String) -> String {
        path.contains(" ") ? "'\(path)'" : path
    }

    public func send(_ text: String) throws {
        let child = try running() ?? spawn()
        child.write([
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": text]]],
        ])
        emit.yield(.busy(true))
        emit.yield(.activity("Thinking…"))
    }

    /// A Claude model's context window, as Claude Code's own `/context`
    /// reports it: the Claude 5 family runs at a million tokens, the 3 and
    /// 4 families (Haiku 4.5 among them) at two hundred thousand.
    static func contextWindow(for model: String?) -> Int {
        guard let model else { return 1_000_000 }
        if model.contains("haiku") || model.contains("-3") || model.contains("-4") { return 200_000 }
        return 1_000_000
    }

    public var processID: Int32? { running()?.pid }

    private func running() -> PipedChild? {
        guard let child, child.isRunning else { return nil }
        return child
    }

    /// Ends the turn in flight without ending the process: a control
    /// message claude answers by aborting the turn (a result follows) and
    /// staying up, ready for the next message on the same stdin.
    public func interrupt() {
        guard let child = running() else { return }
        interrupting = true
        child.write([
            "type": "control_request",
            "request_id": "int-\(counter)",
            "request": ["subtype": "interrupt"],
        ])
        counter += 1
    }

    /// Graceful first: end of input lets claude finish and exit on its
    /// own; anything still running after a moment is terminated.
    public func stop() {
        guard let child = release() else { return }
        Task { await child.end(grace: .seconds(2)) }
    }

    public func end(within deadline: Duration) async {
        guard let child = release() else { return }
        await child.end(grace: max(.zero, deadline - .seconds(1)))
    }

    /// Lets go of the running agent, for whoever is ending it: from here
    /// the session is idle, and the agent's exit is expected.
    private func release() -> PipedChild? {
        guard let child else { return nil }
        self.child = nil
        emit.yield(.activity(nil))
        emit.yield(.busy(false))
        return child
    }

    private func spawn() throws -> PipedChild {
        guard let executable = ToolPath.resolve(tool) else { throw AgentProcessError.toolMissing(tool) }
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        // Visor's MCP server: the other sessions, and in manual mode the
        // permission prompt answered from the client.
        let mcp = VisorMCP.claudeConfig(approvalEnvironment, approvals: !skipPermissions)
        if let mcp { args += ["--mcp-config", mcp] }
        if skipPermissions {
            args += ["--permission-mode", "bypassPermissions"]
        } else {
            // Manual: edits are accepted, everything else asks the user.
            args += ["--permission-mode", "acceptEdits"]
            if mcp != nil { args += ["--permission-prompt-tool", "mcp__visor__approve"] }
        }
        if let model, !model.isEmpty { args += ["--model", model] }
        if let effort, !effort.isEmpty { args += ["--effort", effort] }
        if let resumeID { args += ["--resume", resumeID] }
        // The agent is told which session it is, so it can name itself
        // when it asks the server to restart (VISOR_SESSION).
        let environment = ToolPath.environment().merging(approvalEnvironment) { _, ours in ours }
        let child = try PipedChild(executable: executable, arguments: args,
                                   directory: (cwd as NSString).expandingTildeInPath, environment: environment)
        self.child = child
        interrupting = false
        let tool = self.tool
        // Everything it says, in order, and then how it ended.
        Task { [weak self] in
            for await output in child.output.lines({ ClaudeOutput.parse($0) }) {
                guard let self else { return }
                if self.child === child { self.take(output) }
            }
            let exit = await child.exit.value
            guard let self, self.child === child else { return }
            self.child = nil
            self.emit.yield(.activity(nil))
            self.emit.yield(.busy(false))
            if exit.status != 0, !exit.signaled { self.emit.yield(.failure("\(tool) exited with status \(exit.status)")) }
        }
        Task { [weak self] in
            for await line in child.errors.lines({ $0.contains("Error") || $0.contains("error") ? [$0] : [] }) {
                guard let self else { return }
                if self.child === child { self.emit.yield(.failure(line)) }
            }
        }
        return child
    }

    private func take(_ output: ClaudeOutput) {
        switch output {
        case .commands(let list):
            emit.yield(.commands(list))
        case .began(let session, let model):
            if let session {
                resumeID = session
                emit.yield(.session(session))
            }
            if let model, !model.isEmpty { emit.yield(.model(model)) }
        case .messageStarted(let id):
            // A new message begins: its own row from here on, never run
            // together with the one before (a tool call between two
            // messages gives no separator).
            streamCounter += 1
            streamingMessageID = id ?? "stream-\(streamCounter)"
        case .text(let text):
            emit.yield(.delta(message: streamingMessageID, text: text))
        case .blockStarted(let thinking):
            if thinking { emit.yield(.activity("Thinking…")) }
            emit.yield(.thinking(thinking))
        case .assistant(let model, let tokens, let tools):
            if let model, !model.isEmpty { emit.yield(.model(model)) }
            if tokens > 0 { emit.yield(.context(used: tokens, limit: Self.contextWindow(for: model))) }
            for tool in tools {
                emit.yield(.activity(tool.label))
                counter += 1
                emit.yield(.toolStarted(id: tool.id ?? "tool-\(counter)", name: tool.name, label: tool.label, tasks: tool.tasks))
            }
        case .toolResults(let ids):
            for id in ids { emit.yield(.toolFinished(id: id)) }
            emit.yield(.activity("Thinking…"))
            emit.yield(.thinking(true))
        case .result(let failure):
            // An interrupt ends the turn with an error result of its own
            // (error_during_execution); that is the stop the user asked
            // for, not something to show as a failure.
            let wasInterrupt = interrupting
            interrupting = false
            if !wasInterrupt, let failure { emit.yield(.failure(failure)) }
            emit.yield(.activity(nil))
            emit.yield(.busy(false))
        }
    }
}
