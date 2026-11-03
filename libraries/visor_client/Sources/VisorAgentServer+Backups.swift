// Backing a server's sessions up to a folder on its computer, and
// restoring them from one (`/api/backups`; docs/protocol.md).

import VisorProtocol

extension VisorAgentServer {
    public var backsUp: Bool { true }

    public func backUp(sessions: [String]?, projects: Bool) async throws -> SessionBackup {
        var body = Envelope(type: "backup")
        body.sessionIDs = sessions
        body.projects = projects
        guard let backup = try await backupCall("POST", "/backups", body).backup else { throw AgentServerError.message("No backup came back") }
        return backup
    }

    public func backups() async throws -> [SessionBackup] {
        try await backupCall("GET", "/backups", nil).backups ?? []
    }

    public func restore(_ path: String, sessions: [String]?) async throws -> (backup: SessionBackup, sessions: [SessionInfo]) {
        var body = Envelope(type: "restore")
        body.path = path
        body.sessionIDs = sessions
        let reply = try await backupCall("POST", "/backups/restore", body)
        guard let backup = reply.backup else { throw AgentServerError.message("Nothing was restored") }
        return (backup, reply.sessions ?? [])
    }

    /// One call, its refusal said in the server's own words; a server from
    /// before backups says so.
    private func backupCall(_ method: String, _ path: String, _ body: Envelope?) async throws -> Envelope {
        do {
            let reply = try await call(method, path, body)
            if reply.type == "error" { throw AgentServerError.message(reply.message ?? reply.error ?? "The server refused") }
            return reply
        } catch let error as AgentServerError {
            throw error
        } catch {
            // "HTTP 400: {…}": the envelope after the status says why.
            let text = "\(error)"
            if text.contains("404") { throw AgentServerError.message("This computer's Visor Server is too old to back sessions up: update it.") }
            if let start = text.firstIndex(of: "{"), let reply = Envelope.decode(String(text[start...]), defaultType: "reply"),
               let said = reply.message ?? reply.error {
                throw AgentServerError.message(said)
            }
            throw error
        }
    }
}
