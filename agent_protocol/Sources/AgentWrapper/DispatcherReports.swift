import AgentProtocol
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

/// What the wrapper tells its dispatcher (AGENT_DISPATCHER_URL) of its
/// job: started (with the harness's session), completed, failed. A runner
/// releases a job its wrapper ends without reporting.
public struct DispatcherReports: Sendable {
    public let host: String
    public let port: Int
    let agent: AgentProtocol_V1_AgentID
    let runner: String

    /// Nil for an address that isn't `http://host:port`.
    public init?(url: String, agent: AgentProtocol_V1_AgentID, runner: String) {
        guard let components = URLComponents(string: url), components.scheme == "http", let host = components.host, !host.isEmpty
        else { return nil }
        self.host = host
        port = components.port ?? 80
        self.agent = agent
        self.runner = runner
    }

    public func started(session: String) async throws {
        try await send(.with { $0.started = .with { $0.sessionID = session; $0.runner = runner } })
    }

    public func completed(summary: String) async throws {
        try await send(.with { $0.completed = .with { $0.summary = summary } })
    }

    public func failed(reason: String) async throws {
        try await send(.with { $0.failed = .with { $0.reason = reason } })
    }

    private func send(_ event: AgentProtocol_V1_JobReport) async throws {
        var report = event
        report.agent = agent
        let transport = try HTTP2ClientTransport.Posix(target: .dns(host: host, port: port), transportSecurity: .plaintext)
        try await withGRPCClient(transport: transport) { client in
            _ = try await AgentProtocol_V1_AgentDispatcher.Client(wrapping: client).report(report)
        }
    }
}
