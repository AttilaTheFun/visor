// The Sessions container of a server, as Settings shows it
// (docs/containers.md): `GET /api/container`, and Start and Stop
// (`POST /api/container/start`, `/stop`), each an admin's call; and as
// Migrate… asks of it, whether it takes sessions now.

import VisorProtocol
import VisorServices

extension VisorAgentServer {
    /// How it stands.
    public func containerStatus() async throws -> ContainerStatus {
        try Self.containerStatus(from: try await callText("GET", "/container", body: ""))
    }

    /// Started (with no egress, its check run again): how it stands after.
    public func startContainer() async throws -> ContainerStatus {
        try Self.containerStatus(from: try await callText("POST", "/container/start", body: ""))
    }

    /// Stopped: how it stands after.
    public func stopContainer() async throws -> ContainerStatus {
        try Self.containerStatus(from: try await callText("POST", "/container/stop", body: ""))
    }

    /// How it stands, or nil from a server that doesn't say (before 0.64,
    /// or not reached).
    public func sessionsContainer() async -> ContainerStatus? {
        try? await containerStatus()
    }

    static func containerStatus(from text: String) throws -> ContainerStatus {
        guard let json = parseJSON(text), let status = ContainerStatus(json: json) else {
            throw AgentServerError.message(Self.said(text) ?? "The server said nothing of its container")
        }
        return status
    }
}
