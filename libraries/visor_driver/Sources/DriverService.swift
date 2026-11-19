// agent_protocol's AgentDriver, served by Visor's server: each wrapper
// that dials in shows its agent's token (Job.token, as `authorization:
// Bearer`; JobQueue+Tokens) and says who it is, and its session is taken in
// (a new one, or the one it had); its stream is that session's process from
// then on. A wrapper whose token isn't the agent's it names is refused; one
// whose token has expired is refused too, and its session carried on by a
// new job with a fresh token (VisorServer.resumeAfterExpiredToken: only
// while no wrapper of it is connected, and once per session in
// expiredTokenResumeInterval). While
// connected, it is sent a fresh token before the one it holds ends
// (DriverMessage.token). The agent's MCP requests over the stream are
// answered for that session (DrivenMCP), and its permission prompts are the
// session's (DrivenProcess). What its hello says it understands
// (WrapperHello.protocol) is kept with its process: one that says 2 is
// asked to hand its session back when it moves back (DriverMessage.hand_back),
// and returns its conversation (ReturnConversation: the agent's token
// shown, its runner's claim held, its places held to a move's rules and
// put under this computer's key for the folder the session comes back to;
// ReturnedConversationIntake, VisorServer+HandBack).

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
        // MultiPass's name for this driver, which its wrapper dialled:
        // deprecated (MultiPass is retired), logged the first time in a run.
        if let dialled = request.metadata[stringValues: ":authority"].first(where: JobQueue.namesMultiPass) {
            Deprecated.multipassName.noted("a wrapper dialled \(dialled)")
        }
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
        // Its tokens are the server's to verify: once it is served.
        let server = await listening.ready()
        // The token says which agent it is: the one the hello names, or the
        // wrapper is refused before anything of the session is touched.
        switch await jobs.access(agent, bearer: bearer) {
        case .granted:
            break
        case .unknown:
            VisorServer.log("driver: \(agent) dialled in, but this dispatcher holds no job of that agent: refused")
            throw AgentBearer.refusal("This dispatcher holds no job of that agent.")
        case .expired:
            let session = await jobs.session(of: agent)
            // Its wrapper's stream still live: this isn't that wrapper back
            // after a long absence (whose stream has gone), but someone
            // else's copy of an old token. Refused, and nothing restarted.
            let live = await MainActor.run { (server.session(session)?.process as? DrivenProcess)?.isAttached == true }
            if live {
                VisorServer.log("driver: \(agent) dialled in with an expired token while its wrapper is connected: refused")
            } else {
                VisorServer.log("driver: \(agent) dialled in with an expired token: refused; its session carried on with a fresh one")
                await MainActor.run { server.resumeAfterExpiredToken(session, agent: agent) }
            }
            throw AgentBearer.refusal(AgentTokenRefusal.expired.message)
        case .refused(let why):
            VisorServer.log("driver: \(agent) dialled in: refused: \(why)")
            throw AgentBearer.refusal(why)
        }
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
            process.wrapperProtocol = hello.protocol
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
        // A fresh token before the one it holds ends, for as long as it is
        // connected: shown on its next connection and every other call.
        let refreshing = Task { await refreshTokens(of: agent, from: bearer) { sending.yield($0) } }
        defer {
            refreshing.cancel()
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

    /// Sends the agent a fresh token (DriverMessage.token) a sixth of its
    /// life before each it holds ends (ten minutes of an hour), starting
    /// from the one it dialled in with, until cancelled.
    private func refreshTokens(of agent: String, from shown: String?, send: @escaping @Sendable (AgentProtocol_V1_DriverMessage) -> Void) async {
        var ends: Date?
        if let shown { ends = await jobs.expiry(of: shown) }
        while !Task.isCancelled {
            let lead = await jobs.tokenRefreshLead
            let wait = max(0.05, (ends ?? Date()).timeIntervalSinceNow - lead)
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
            guard !Task.isCancelled, await jobs.holds(agent) else { return }
            let fresh = await jobs.token(for: agent)
            send(.with { $0.token = fresh })
            ends = await jobs.expiry(of: fresh)
            VisorServer.log("driver: \(agent) sent a fresh token")
        }
    }

    /// A moved session's conversation, before its wrapper starts its harness:
    /// each of its files in pieces, its place for the folder it will work
    /// in. Only for the agent whose token the call shows.
    func conversation(request: ServerRequest<AgentProtocol_V1_ConversationRequest>,
                      context: ServerContext) async throws -> StreamingServerResponse<AgentProtocol_V1_ConversationFile> {
        let agent = request.message.agent.uuid
        _ = await listening.ready()
        switch await jobs.access(agent, bearer: AgentBearer.token(in: request.metadata)) {
        case .granted:
            break
        case .unknown:
            VisorServer.log("driver: \(agent) asked for a conversation, but this dispatcher holds no job of that agent: refused")
            return StreamingServerResponse(error: AgentBearer.refusal("This dispatcher holds no job of that agent."))
        case .expired:
            VisorServer.log("driver: \(agent) asked for a conversation with an expired token: refused")
            return StreamingServerResponse(error: AgentBearer.refusal(AgentTokenRefusal.expired.message))
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

    /// A handed-back session's conversation, returned by its runner's
    /// wrapper once its agent has ended (DriverMessage.hand_back): the
    /// header, then its files. Only for the agent whose token the call
    /// shows, whose runner holds its claim, and whose session is moving
    /// back and waits for that agent's conversation; each place held to
    /// what a hand-back returns and to a move's caps, staged as it comes,
    /// and put under this computer's key for the folder the session comes
    /// back to (ReturnedConversationIntake). Refused, nothing is written,
    /// and the session comes back without it.
    func returnConversation(request: StreamingServerRequest<AgentProtocol_V1_ReturnedConversation>,
                            context: ServerContext) async throws -> ServerResponse<AgentProtocol_V1_ReturnedConversationAck> {
        let bearers = AgentBearer.tokens(in: request.metadata)
        let server = await listening.ready()
        var messages = request.messages.makeAsyncIterator()
        guard let first = try await messages.next(), case .header(let header) = first.part else {
            return ServerResponse(error: RPCError(code: .failedPrecondition, message: "A returned conversation's first message is its header."))
        }
        let agent = header.agent.uuid
        if let refusal = await admitReturn(of: agent, bearers: bearers, server) { return ServerResponse(error: refusal) }
        let session = await jobs.session(of: agent)
        guard let target = await MainActor.run(body: { server.handBackArriving(session, agent: agent) }) else {
            VisorServer.log("driver: \(agent) returned a conversation, but \(session) isn't moving back for it: refused")
            return ServerResponse(error: RPCError(code: .failedPrecondition, message: "This agent's session isn't moving back for its conversation here."))
        }
        var intake: ReturnedConversationIntake?
        do {
            let taking = try ReturnedConversationIntake(target: target, harness: header.harness, workingDirectory: header.workingDirectory,
                                                        sessionID: header.sessionID)
            intake = taking
            while let message = try await messages.next() {
                guard case .file(let piece) = message.part else {
                    throw ReturnedConversationIntake.Refusal(.unsafe, "it sends something other than a file after its header")
                }
                try taking.take(place: piece.place, data: piece.data, last: piece.last)
            }
            let staged = try taking.finish()
            switch await MainActor.run(body: { server.placeReturned(staged) }) {
            case .success:
                VisorServer.log("driver: \(agent) returned \(header.sessionID.isEmpty ? "no conversation" : header.sessionID), "
                    + "\(staged.files.count) files, for \(session)")
                return ServerResponse(message: .with { $0.files = Int64(staged.files.count); $0.sessionID = header.sessionID })
            case .failure(let refusal):
                VisorServer.log("driver: \(agent)'s returned conversation not taken: \(refusal.why)")
                return ServerResponse(error: Self.error(refusal))
            }
        } catch {
            intake?.discard()
            let refusal = (error as? ReturnedConversationIntake.Refusal) ?? .init(.unwritable, "its call ended: \(error)")
            VisorServer.log("driver: \(agent)'s returned conversation refused: \(refusal.why)")
            await MainActor.run { server.handBackFailed(session, agent: agent, why: refusal.why) }
            return ServerResponse(error: Self.error(refusal))
        }
    }

    /// Why a ReturnConversation for `agent` showing `bearers` isn't let in:
    /// nil when its token is the agent's own, live, its runner holds its
    /// claim, and any runner token beside it is that runner's.
    private func admitReturn(of agent: String, bearers: [String], _ server: VisorServer) async -> RPCError? {
        switch await jobs.access(agent, bearers: bearers) {
        case .granted:
            break
        case .unknown:
            VisorServer.log("driver: \(agent) returned a conversation, but this dispatcher holds no job of that agent: refused")
            return AgentBearer.refusal("This dispatcher holds no job of that agent.")
        case .expired:
            VisorServer.log("driver: \(agent) returned a conversation with an expired token: refused")
            return AgentBearer.refusal(AgentTokenRefusal.expired.message)
        case .refused(let why):
            VisorServer.log("driver: \(agent) returned a conversation: refused: \(why)")
            return AgentBearer.refusal(why)
        }
        guard let holder = await jobs.holder(of: agent) else {
            VisorServer.log("driver: \(agent) returned a conversation, but no runner holds its claim: refused")
            return RPCError(code: .permissionDenied, message: "No runner holds this agent's claim.")
        }
        if let refusal = await MainActor.run(body: { AgentBearer.refusal(server.runnerTokens.admit(callFor: holder, bearers: bearers)) }) {
            VisorServer.log("driver: \(agent)'s returned conversation refused: \(refusal.message)")
            return refusal
        }
        return nil
    }

    /// What a returned conversation that isn't taken is refused with.
    private static func error(_ refusal: ReturnedConversationIntake.Refusal) -> RPCError {
        let code: RPCError.Code = switch refusal.kind {
        case .unsafe: .invalidArgument
        case .tooLarge, .noRoom: .resourceExhausted
        case .unwritable: .internalError
        case .ended: .failedPrecondition
        }
        return RPCError(code: code, message: "The conversation wasn't taken: \(refusal.why).")
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
