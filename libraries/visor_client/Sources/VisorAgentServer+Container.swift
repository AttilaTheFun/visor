// The Sessions container of a server, as Settings shows it
// (docs/containers.md): `GET /api/container`, and Start and Stop
// (`POST /api/container/start`, `/stop`), each an admin's call; and as
// Migrate… asks of it, whether it takes sessions now; New Session's
// session started in it (`POST /api/container/sessions`); and the Claude
// credential its agents reach Anthropic with, set and removed
// (`POST` and `DELETE /api/container/claude`), never read back.

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

    /// A new Claude Code session in it, once its agent has started there
    /// (`{title, model, effort, text}`): the session, as the server lists
    /// it; or what the server said in refusing it (off, not ready, its
    /// agent unable to start), as the message thrown.
    public func startSessionInContainer(title: String, model: String?, effort: String?, text: String?) async throws -> SessionInfo {
        var body = Envelope(type: "start")
        body.title = title
        body.model = model
        body.effort = effort
        body.text = text
        let reply: Envelope
        do {
            reply = try await call("POST", "/container/sessions", body)
        } catch {
            if let answer = VisorHost.http?.body(of: error), let said = Self.said(answer) { throw AgentServerError.message(said) }
            throw error
        }
        guard let started = reply.sessions?.first else {
            throw AgentServerError.message(reply.message ?? "The server started no session in its container")
        }
        return started
    }

    /// The Claude credential kept (nil: removed): how it stands after, or
    /// the server's refusal in its words.
    public func setContainerClaudeCredential(_ token: String?) async throws -> ContainerStatus {
        var body = Envelope(type: "claude")
        body.text = token
        do {
            return try Self.containerStatus(from: try await callText(token == nil ? "DELETE" : "POST", "/container/claude",
                                                                     body: token == nil ? "" : body.encoded()))
        } catch {
            if let answer = VisorHost.http?.body(of: error), let said = Self.said(answer) { throw AgentServerError.message(said) }
            throw error
        }
    }

    static func containerStatus(from text: String) throws -> ContainerStatus {
        guard let json = parseJSON(text), let status = ContainerStatus(json: json) else {
            throw AgentServerError.message(Self.said(text) ?? "The server said nothing of its container")
        }
        return status
    }
}
