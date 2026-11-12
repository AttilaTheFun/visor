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

    func connect(request: RPCAsyncSequence<AgentProtocol_V1_WrapperMessage, any Error>,
                 response: RPCWriter<AgentProtocol_V1_DriverMessage>, context: ServerContext) async throws {
        var messages = request.makeAsyncIterator()
        guard let first = try await messages.next(), case .hello(let hello) = first.message else {
            throw RPCError(code: .failedPrecondition, message: "A wrapper's first message is its hello.")
        }
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
