import AgentProtocol
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

/// The wrapper's line to its driver (AGENT_DRIVER_URL): dialled out, kept
/// open, dialled again after a drop, until the agent ends. On each
/// connection it says who it is, then everything the agent has said and is
/// doing, then what changes; and it takes what the driver sends (messages,
/// an interrupt, a stop).
public struct DriverLink: Sendable {
    public let host: String
    public let port: Int
    let core: AgentCore
    let hostName: String
    let log: @Sendable (String) -> Void

    /// Nil for an address that isn't `http://host:port`.
    public init?(url: String, core: AgentCore, hostName: String, log: @escaping @Sendable (String) -> Void = { _ in }) {
        guard let components = URLComponents(string: url), components.scheme == "http", let host = components.host, !host.isEmpty
        else { return nil }
        self.host = host
        port = components.port ?? 80
        self.core = core
        self.hostName = hostName
        self.log = log
    }

    /// Connected, and again after each drop (1 s, doubling to 30 s
    /// between tries), until the agent ends.
    public func run() async {
        var pause: Duration = .seconds(1)
        while !Task.isCancelled {
            let ended = await core.attach().ended
            if ended != nil { return }
            do {
                try await connectOnce()
                pause = .seconds(1)
            } catch {
                log("driver \(host):\(port): \(error)")
            }
            if await core.attach().ended != nil { return }
            try? await Task.sleep(for: pause)
            pause = min(pause * 2, .seconds(30))
        }
    }

    private func connectOnce() async throws {
        let transport = try HTTP2ClientTransport.Posix(target: .dns(host: host, port: port), transportSecurity: .plaintext)
        let core = self.core
        let hello = await helloMessage()
        let log = self.log
        try await withGRPCClient(transport: transport) { client in
            let driver = AgentProtocol_V1_AgentDriver.Client(wrapping: client)
            try await driver.connect(requestProducer: { writer in
                let (rows, state, sessionID, ended, changes) = await core.attach()
                var first = hello
                first.sessionID = sessionID
                try await writer.write(.with { $0.hello = first })
                if !rows.isEmpty { try await writer.write(.with { $0.entries = .with { $0.entries = rows } }) }
                try await writer.write(.with { $0.state = state })
                if let ended {
                    try await writer.write(.with { $0.ended = ended })
                    return
                }
                for await change in changes {
                    switch change {
                    case .entry(let row): try await writer.write(.with { $0.entries = .with { $0.entries = [row] } })
                    case .state(let state): try await writer.write(.with { $0.state = state })
                    case .sessionID(let id): try await writer.write(.with { $0.sessionID = id })
                    case .ended(let why): try await writer.write(.with { $0.ended = why })
                    }
                }
            }, onResponse: { response in
                for try await message in response.messages {
                    switch message.message {
                    case .send(let send): await core.send(id: send.id.isEmpty ? UUID().uuidString.lowercased() : send.id, text: send.text)
                    case .stop: await core.stop()
                    case .interrupt: log("driver: an interrupt isn't supported by this harness yet")
                    case .model(let change): log("driver: changing the model to \(change.model) isn't supported yet")
                    case .approval, .acknowledged, .none: break
                    }
                }
            })
        }
    }

    private func helloMessage() async -> AgentProtocol_V1_WrapperMessage.OneOf_Message.Hello {
        var hello = AgentProtocol_V1_WrapperHello()
        hello.protocol = 1
        hello.agent = core.agent
        hello.spec = core.spec
        hello.hostName = hostName
        return hello
    }
}

extension AgentProtocol_V1_WrapperMessage.OneOf_Message {
    public typealias Hello = AgentProtocol_V1_WrapperHello
}
