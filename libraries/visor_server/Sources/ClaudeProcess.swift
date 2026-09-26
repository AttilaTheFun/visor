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

public final class ClaudeProcess: AgentProcess {
    public var onEvent: (@Sendable (AgentEvent) -> Void)?

    private let cwd: String
    /// "claude", or another CLI speaking the same stream-json protocol ("ori").
    private let tool: String
    public var skipPermissions: Bool
    public var model: String?
    public var effort: String?
    public var onModel: (@Sendable (String) -> Void)?
    public var approvalEnvironment: [String: String] = [:]
    private var process: Process?
    private var stdin: FileHandle?
    private var reader: LineReader?
    private var stderrReader: LineReader?
    private var sessionID: String?
    public var resumeID: String? { queue.sync { sessionID } }
    public var resumeCommand: String? {
        guard let id = resumeID else { return nil }
        return "cd \(ClaudeProcess.quoted(cwd)) && \(tool) --resume \(id)"
    }
    private let queue = DispatchQueue(label: "visor.claude")
    /// The assistant message being assembled (its blocks arrive one event
    /// each), as ordered segments: a text block after tool calls opens a new
    /// one, so what the model said and what it ran stay interleaved.
    private var assembling: (id: String, segments: [(text: String, activities: [String])])?
    private var counter = 0
    /// Set by `stop()`: the exit that follows is ours, not a failure.
    private var stopping = false
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
        self.sessionID = resume
        self.tool = tool
    }

    static func quoted(_ path: String) -> String {
        path.contains(" ") ? "'\(path)'" : path
    }

    public func send(_ text: String) throws {
        try queue.sync {
            if process == nil || process?.isRunning != true { try spawn() }
            let message: [String: Any] = [
                "type": "user",
                "message": ["role": "user", "content": [["type": "text", "text": text]]],
            ]
            let data = try JSONSerialization.data(withJSONObject: message)
            stdin?.write(data)
            stdin?.write("\n".data(using: .utf8)!)
            onEvent?(.busy(true))
            onEvent?(.activity("Thinking…"))
        }
    }

    /// A Claude model's context window, as Claude Code's own `/context`
    /// reports it: the Claude 5 family runs at a million tokens, the 3 and
    /// 4 families (Haiku 4.5 among them) at two hundred thousand.
    static func contextWindow(for model: String?) -> Int {
        guard let model else { return 1_000_000 }
        if model.contains("haiku") || model.contains("-3") || model.contains("-4") { return 200_000 }
        return 1_000_000
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
            stopping = true
            // End of input: claude finishes what it is doing and exits.
            try? stdin?.close()
            stdin = nil
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
        onEvent?(.activity(nil))
        onEvent?(.busy(false))
    }

    /// Ends the turn in flight without ending the process: a control
    /// message claude answers by aborting the turn (a result follows) and
    /// staying up, ready for the next message on the same stdin.
    public func interrupt() {
        queue.sync {
            guard process?.isRunning == true, let stdin else { return }
            interrupting = true
            let message: [String: Any] = [
                "type": "control_request",
                "request_id": "int-\(counter)",
                "request": ["subtype": "interrupt"],
            ]
            counter += 1
            if let data = try? JSONSerialization.data(withJSONObject: message) {
                stdin.write(data)
                stdin.write("\n".data(using: .utf8)!)
            }
        }
    }

    public func stop() {
        queue.sync {
            guard let running = process else { return }
            stopping = true
            process = nil
            // Graceful first: end of input lets claude finish and exit on its
            // own; anything still running after a moment is terminated.
            try? stdin?.close()
            stdin = nil
            queue.asyncAfter(deadline: .now() + 2) {
                if running.isRunning { running.terminate() }
            }
            onEvent?(.activity(nil))
            onEvent?(.busy(false))
        }
    }

    private func spawn() throws {
        guard let executable = ToolPath.resolve(tool) else { throw AgentProcessError.toolMissing(tool) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
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
        if let sessionID { args += ["--resume", sessionID] }
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
            if line.contains("Error") || line.contains("error") { self?.onEvent?(.failure(line)) }
        }
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.queue.async {
                if self.process === proc { self.process = nil; self.stdin = nil }
                let expected = self.stopping
                self.stopping = false
                self.onEvent?(.activity(nil))
                self.onEvent?(.busy(false))
                if !expected, proc.terminationStatus != 0, proc.terminationReason == .exit {
                    self.onEvent?(.failure("\(self.tool) exited with status \(proc.terminationStatus)"))
                }
            }
        }
        do { try p.run() } catch { throw AgentProcessError.spawnFailed("\(error)") }
        process = p
        stdin = input.fileHandleForWriting
    }

    private func handle(_ line: String) {
        guard let object = JSON.object(line), let type = object["type"] as? String else { return }
        switch type {
        case "system":
            if object["subtype"] as? String == "init" {
                if let id = object["session_id"] as? String {
                    sessionID = id
                    onEvent?(.session(id))
                }
                if let model = object["model"] as? String, !model.isEmpty { onModel?(model) }
            }
        case "stream_event":
            guard let event = object["event"] as? [String: Any], let kind = event["type"] as? String else { return }
            if kind == "message_start", let message = event["message"] as? [String: Any] {
                // A new message begins: its own row from here on, never
                // run together with the one before (a tool call between
                // two messages gives no separator).
                streamCounter += 1
                streamingMessageID = message["id"] as? String ?? "stream-\(streamCounter)"
            } else if kind == "content_block_delta", let delta = event["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                onEvent?(.delta(message: streamingMessageID, text: text))
            } else if kind == "content_block_start", let block = event["content_block"] as? [String: Any] {
                let thinking = block["type"] as? String == "thinking"
                if thinking { onEvent?(.activity("Thinking…")) }
                onEvent?(.thinking(thinking))
            }
        case "assistant":
            guard let message = object["message"] as? [String: Any], let id = message["id"] as? String,
                  let content = message["content"] as? [[String: Any]] else { return }
            if let model = message["model"] as? String, !model.isEmpty { onModel?(model) }
            // The request's own tokens: what the context holds right now.
            if let usage = message["usage"] as? [String: Any] {
                let used = (usage["input_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                    + (usage["cache_read_input_tokens"] as? Int ?? 0)
                if used > 0 {
                    onEvent?(.context(used: used, limit: Self.contextWindow(for: message["model"] as? String)))
                }
            }
            if assembling?.id != id { assembling = (id, [(text: "", activities: [])]) }
            for block in content {
                switch block["type"] as? String {
                case "text":
                    guard let text = block["text"] as? String, !text.isEmpty, var segments = assembling?.segments else { break }
                    if let last = segments.indices.last, segments[last].activities.isEmpty, segments[last].text.isEmpty {
                        segments[last].text = text
                    } else if let last = segments.indices.last, segments[last].activities.isEmpty {
                        segments[last].text += "\n\n" + text
                    } else {
                        segments.append((text: text, activities: []))
                    }
                    assembling?.segments = segments
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    let label = "\(name): \(JSON.summary(block["input"]))"
                    if let last = assembling?.segments.indices.last { assembling?.segments[last].activities.append(label) }
                    onEvent?(.activity(label))
                    counter += 1
                    onEvent?(.toolStarted(id: block["id"] as? String ?? "tool-\(counter)", name: name, label: label,
                                          tasks: TurnStatus.tasks(named: name, input: block["input"] as? [String: Any])))
                default: break
                }
            }
            // Claude Code's own session file is the transcript of record
            // (the server follows it); the rows are announced from here
            // only for a tool that speaks the protocol without the file.
            if let assembling, tool != "claude" {
                for (index, segment) in assembling.segments.enumerated() {
                    onEvent?(.entry(TranscriptEntry(id: index == 0 ? assembling.id : "\(assembling.id)#\(index)", role: .assistant,
                                                    text: segment.text, activities: segment.activities)))
                }
            }
        case "user":
            // A tool result: the tool finished; the transcript hides these rows.
            guard let message = object["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { return }
            let recordUUID = object["uuid"] as? String
            for block in content where block["type"] as? String == "tool_result" {
                if let id = block["tool_use_id"] as? String { onEvent?(.toolFinished(id: id)) }
            }
            for block in content where block["type"] as? String == "tool_result" && tool != "claude" {
                counter += 1
                let text: String
                var images: [String] = []
                if let s = block["content"] as? String { text = s }
                else if let parts = block["content"] as? [[String: Any]] {
                    text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    // A screenshot the agent took, or an image it read: the
                    // bytes arrive inline and are far too big to keep in a
                    // transcript, so they are put down on disk and the row
                    // carries the path.
                    for part in parts where part["type"] as? String == "image" {
                        guard let source = part["source"] as? [String: Any],
                              let data = source["data"] as? String else { continue }
                        if let path = AgentImages.save(base64: data, mediaType: source["media_type"] as? String) {
                            images.append(path)
                        }
                    }
                } else { text = "" }
                // The id the file assembler gives this same record, so a
                // stream row and the file's row are one row, not two.
                let id = recordUUID.map { "tool-file-" + $0 } ?? "tool-\(counter)-\(UUID().uuidString.prefix(6))"
                onEvent?(.entry(TranscriptEntry(id: id, role: .tool,
                                                text: String(text.prefix(400)), toolName: "tool_result", images: images,
                                                imageSizes: AgentImages.pixelSizes(paths: images))))
            }
            onEvent?(.activity("Thinking…"))
            onEvent?(.thinking(true))
        case "result":
            assembling = nil
            // An interrupt ends the turn with an error result of its own
            // (error_during_execution); that is the stop the user asked
            // for, not something to show as a failure.
            let wasInterrupt = interrupting
            interrupting = false
            if !wasInterrupt, object["is_error"] as? Bool == true {
                onEvent?(.failure((object["result"] as? String) ?? "The turn failed"))
            }
            onEvent?(.activity(nil))
            onEvent?(.busy(false))
        default:
            break
        }
    }
}
