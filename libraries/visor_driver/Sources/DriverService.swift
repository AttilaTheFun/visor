// agent_protocol's AgentDriver, served by Visor's server: each wrapper
// that dials in says who it is, and its session is taken in (a new one, or
// the one it had); its stream is that session's process from then on.

import AgentProtocol
import Foundation
import GRPCCore
import VisorProtocol
import VisorServer

struct DriverService: AgentProtocol_V1_AgentDriver.SimpleServiceProtocol {
    let server: VisorServer
    /// Where moved sessions' conversations are known (JobQueue.move).
    let jobs: JobQueue

    func connect(request: RPCAsyncSequence<AgentProtocol_V1_WrapperMessage, any Error>,
                 response: RPCWriter<AgentProtocol_V1_DriverMessage>, context: ServerContext) async throws {
        var messages = request.makeAsyncIterator()
        guard let first = try await messages.next(), case .hello(var hello) = first.message else {
            throw RPCError(code: .failedPrecondition, message: "A wrapper's first message is its hello.")
        }
        // The session is the agent's id as the dispatcher issued it, however
        // the wrapper spells it.
        hello.agent.uuid = JobQueue.key(hello.agent.uuid)
        guard !hello.agent.uuid.isEmpty else { throw RPCError(code: .invalidArgument, message: "The hello names no agent.") }
        let (outgoing, sending) = AsyncStream<AgentProtocol_V1_DriverMessage>.makeStream()
        let server = self.server
        let (process, connection) = await MainActor.run { () -> (DrivenProcess, UUID) in
            let process = (server.session(hello.agent.uuid)?.process as? DrivenProcess) ?? DrivenProcess()
            server.takeDriven(Self.info(hello), process: process)
            let connection = process.attach { sending.yield($0) }
            return (process, connection)
        }
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
                await MainActor.run { process.take(message) }
            }
        } catch {
            VisorServer.log("driver: \(hello.agent.uuid): \(error)")
        }
        await MainActor.run { process.detach(connection) }
        VisorServer.log("driver: \(hello.agent.uuid) disconnected")
    }

    /// A moved session's conversation, before its wrapper starts its harness:
    /// each of its files in pieces, its place for the folder it will work in.
    func conversation(request: AgentProtocol_V1_ConversationRequest, response: RPCWriter<AgentProtocol_V1_ConversationFile>,
                      context: ServerContext) async throws {
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
