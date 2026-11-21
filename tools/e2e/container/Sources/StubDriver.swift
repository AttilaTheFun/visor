// A stand-in for Visor's driver (agent_protocol's AgentDriver) in
// //tools/e2e/container, on a free loopback port of this process (never
// 7434, the installed server's): the container's driver link is carried to
// it, so a wrapper in the guest dialling AGENT_DRIVER_URL
// (http://127.0.0.1:7434 there) reaches it. It keeps each Connect's hello
// and bearer, sends the wrapper one message, and once the agent has answered
// it ("echo: …", the stand-in claude's), stops the agent. No conversation
// to give or take.

import AgentProtocol
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Synchronization

final class StubDriver: AgentProtocol_V1_AgentDriver.ServiceProtocol {
    /// What the wrapper sends it, and what it heard.
    static let message = "hello from the stub driver"

    struct Heard: Sendable {
        var hello: AgentProtocol_V1_WrapperHello?
        var bearer: String?
        var answered = false
        var ended: String?
    }

    let heard = Mutex(Heard())

    func connect(request: StreamingServerRequest<AgentProtocol_V1_WrapperMessage>,
                 context: ServerContext) async throws -> StreamingServerResponse<AgentProtocol_V1_DriverMessage> {
        let bearer = request.metadata[stringValues: "authorization"].first { $0.hasPrefix("Bearer ") }.map { String($0.dropFirst(7)) }
        return StreamingServerResponse { response in
            for try await message in request.messages {
                switch message.message {
                case let .hello(said):
                    self.heard.withLock {
                        $0.hello = said
                        $0.bearer = bearer
                    }
                    try await response.write(.with { $0.send = .with { $0.id = "e2e-1"; $0.text = Self.message } })
                case let .entries(rows):
                    let answered = rows.entries.contains { $0.text.contains("echo: \(Self.message)") }
                    let first = self.heard.withLock { heard -> Bool in
                        defer { heard.answered = heard.answered || answered }
                        return answered && !heard.answered
                    }
                    if first { try await response.write(.with { $0.stop = AgentProtocol_V1_Empty() }) }
                case let .ended(why):
                    self.heard.withLock { $0.ended = why }
                default:
                    break
                }
            }
            return [:]
        }
    }

    func conversation(request: ServerRequest<AgentProtocol_V1_ConversationRequest>,
                      context: ServerContext) async throws -> StreamingServerResponse<AgentProtocol_V1_ConversationFile> {
        StreamingServerResponse { _ in [:] }
    }

    func returnConversation(request: StreamingServerRequest<AgentProtocol_V1_ReturnedConversation>,
                            context: ServerContext) async throws -> ServerResponse<AgentProtocol_V1_ReturnedConversationAck> {
        ServerResponse(error: RPCError(code: .unimplemented, message: "the stub driver takes no conversation"))
    }

    /// Served on 127.0.0.1 at a port the system picks: the port, and how
    /// to stop it.
    func start() async throws -> (port: Int, stop: @Sendable () -> Void) {
        let transport = HTTP2ServerTransport.Posix(address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext)
        let server = GRPCServer(transport: transport, services: [self])
        Task { try? await server.serve() }
        guard let port = try await transport.listeningAddress.ipv4?.port else {
            server.beginGracefulShutdown()
            throw CheckError("the stub driver didn't listen on loopback")
        }
        return (port, { server.beginGracefulShutdown() })
    }
}
