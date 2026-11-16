// agent_protocol's AgentDriver, served by Visor's server: each wrapper
// that dials in shows its agent's token (Job.token, as `authorization:
// Bearer`; JobQueue+Tokens) and says who it is, and its session is taken in
// (a new one, or the one it had); its stream is that session's process from
// then on. A wrapper whose token isn't the agent's it names is refused. The
// agent's MCP requests over the stream are answered for that session
// (DrivenMCP), and its permission prompts are the session's (DrivenProcess).

import AgentProtocol
import Foundation
import GRPCCore
import VisorProtocol
import VisorServer

struct DriverService: AgentProtocol_V1_AgentDriver.ServiceProtocol {
    /// The server, once it is served (a wrapper that dials a server still
    /// reading its sessions waits for it).
    let listening: VisorDriver.Listening
    /// Where moved sessions' conversations are known (JobQueue.move), and
    /// the agents' tokens.
    let jobs: JobQueue

    func connect(request: StreamingServerRequest<AgentProtocol_V1_WrapperMessage>,
                 context: ServerContext) async throws -> StreamingServerResponse<AgentProtocol_V1_DriverMessage> {
        let bearer = AgentBearer.token(in: request.metadata)
        guard bearer != nil else {
            VisorServer.log("driver: a wrapper dialled in with no token: refused")
            return StreamingServerResponse(error: AgentBearer.refusal("The call shows no token (authorization: Bearer <Job.token>)."))
        }
        return StreamingServerResponse { response in
            try await serve(request.messages, response, bearer: bearer)
            return [:]
        }
    }

    private func serve(_ request: RPCAsyncSequence<AgentProtocol_V1_WrapperMessage, any Error>,
                       _ response: RPCWriter<AgentProtocol_V1_DriverMessage>, bearer: String?) async throws {
        var messages = request.makeAsyncIterator()
        guard let first = try await messages.next(), case .hello(var said) = first.message else {
            throw RPCError(code: .failedPrecondition, message: "A wrapper's first message is its hello.")
        }
        let agent = said.agent.uuid
        guard !agent.isEmpty else { throw RPCError(code: .invalidArgument, message: "The hello names no agent.") }
        // The token says which agent it is: the one the hello names, or the
        // wrapper is refused before anything of the session is touched.
        switch await jobs.access(agent, bearer: bearer) {
        case .granted:
            break
        case .unknown:
            VisorServer.log("driver: \(agent) dialled in, but this dispatcher holds no job of that agent: refused")
            throw AgentBearer.refusal("This dispatcher holds no job of that agent.")
        case .refused(let why):
            VisorServer.log("driver: \(agent) dialled in: refused: \(why)")
            throw AgentBearer.refusal(why)
        }
        let server = await listening.ready()
        // The session is the agent's id as the dispatcher issued it, however
        // the wrapper spells it; a moved session's agent, the session's own.
        said.agent.uuid = await jobs.session(of: agent)
        let hello = said
        // An earlier agent of a session since restarted or stopped, on its
        // way out, isn't taken for the session's.
        guard await server.carriesDriven(hello.agent.uuid, agent: agent) else {
            VisorServer.log("driver: \(agent) dialled in for \(hello.agent.uuid), which another agent carries on now: refused")
            throw RPCError(code: .failedPrecondition, message: "This agent no longer carries its session on.")
        }
        // Alive: a job queued again for it meanwhile is its own.
        await jobs.heard(agent)
        let (outgoing, sending) = AsyncStream<AgentProtocol_V1_DriverMessage>.makeStream()
        // In a container (its job's kind, or its runner's), or on a native
        // runner: which MCP servers its session gets.
        let inContainer = await jobs.runsInContainer(agent)
        let (process, connection) = await MainActor.run { () -> (DrivenProcess, UUID) in
            let process = (server.session(hello.agent.uuid)?.process as? DrivenProcess) ?? DrivenProcess()
            let record = server.takeDriven(Self.info(hello), process: process)
            record.runsInContainer = inContainer
            let connection = process.attach { sending.yield($0) }
            return (process, connection)
        }
        // The agent's MCP server ("visor", through its wrapper), as its
        // session's: this connection's, as the wrapper's relay is. In a
        // container, Visor's own tools alone; on a native runner, the
        // computer's passed-on servers too, as a native session has.
        let mcp = DrivenMCP(session: hello.agent.uuid, server: server, passesOn: !inContainer) { sending.yield($0) }
        VisorServer.log("driver: \(hello.agent.uuid) connected from \(hello.hostName.isEmpty ? "a wrapper" : hello.hostName)")
        // Down the stream, as the session sends: a task of its own, ended
        // with the connection.
        let writing = Task {
            for await message in outgoing { try await response.write(message) }
        }
        defer {
            sending.finish()
            writing.cancel()
        }
        do {
            while let message = try await messages.next() {
                if case .mcp(let asked) = message.message {
                    await mcp.take(asked)
                } else {
                    await MainActor.run { process.take(message) }
                }
            }
        } catch {
            VisorServer.log("driver: \(hello.agent.uuid): \(error)")
        }
        await mcp.close()
        await MainActor.run { process.detach(connection) }
        VisorServer.log("driver: \(hello.agent.uuid) disconnected")
    }

    /// A moved session's conversation, before its wrapper starts its harness:
    /// each of its files in pieces, its place for the folder it will work
    /// in. Only for the agent whose token the call shows.
    func conversation(request: ServerRequest<AgentProtocol_V1_ConversationRequest>,
                      context: ServerContext) async throws -> StreamingServerResponse<AgentProtocol_V1_ConversationFile> {
        let agent = request.message.agent.uuid
        switch await jobs.access(agent, bearer: AgentBearer.token(in: request.metadata)) {
        case .granted:
            break
        case .unknown:
            VisorServer.log("driver: \(agent) asked for a conversation, but this dispatcher holds no job of that agent: refused")
            return StreamingServerResponse(error: AgentBearer.refusal("This dispatcher holds no job of that agent."))
        case .refused(let why):
            VisorServer.log("driver: \(agent) asked for a conversation: refused: \(why)")
            return StreamingServerResponse(error: AgentBearer.refusal(why))
        }
        let asked = request.message
        return StreamingServerResponse { response in
            try await send(conversationOf: asked, to: response)
            return [:]
        }
    }

    private func send(conversationOf request: AgentProtocol_V1_ConversationRequest,
                      to response: RPCWriter<AgentProtocol_V1_ConversationFile>) async throws {
        _ = await listening.ready()
        guard let move = await jobs.move(of: request.agent) else {
            VisorServer.log("driver: \(request.agent.uuid) asked for a conversation, but it wasn't moved here")
            return
        }
        let files = ConversationFiles.of(resume: move.resume, cwd: move.cwd, for: request.workingDirectory)
        var sent = 0
        for file in files {
            guard let handle = try? FileHandle(forReadingFrom: file.url) else { continue }
            defer { try? handle.close() }
            while true {
                let piece = try handle.read(upToCount: ConversationFiles.piece) ?? Data()
                let last = piece.count < ConversationFiles.piece
                try await response.write(.with { $0.place = file.place; $0.data = piece; $0.last = last })
                if last { break }
            }
            sent += 1
        }
        VisorServer.log("driver: \(request.agent.uuid)'s conversation (\(move.resume)) sent, \(sent) files, for \(request.workingDirectory)")
    }

    /// A session as a wrapper describes its agent: its id is the agent's.
    static func info(_ hello: AgentProtocol_V1_WrapperHello) -> SessionInfo {
        // Visor's kinds: echo (a test's harness) shows as Claude Code's.
        let agent: AgentKind = switch hello.spec.harness {
        case "codex": .codex
        case "openrouter": .openrouter
        default: .claude
        }
        let title = hello.spec.title.isEmpty ? agent.title : hello.spec.title
        var info = SessionInfo(id: hello.agent.uuid, agent: agent, cwd: hello.spec.workingDirectory.isEmpty ? "~" : hello.spec.workingDirectory,
                               title: title, skipPermissions: hello.spec.skipPermissions,
                               model: hello.spec.model.isEmpty ? nil : hello.spec.model, created: Date().timeIntervalSince1970)
        if !hello.spec.effort.isEmpty { info.effort = hello.spec.effort }
        return info
    }
}
