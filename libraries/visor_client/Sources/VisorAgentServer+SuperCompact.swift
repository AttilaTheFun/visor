// Super Compact over the server's REST side (docs/super-compact.md,
// docs/protocol.md): the job started, followed and cancelled
// (`/api/sessions/<id>/super-compact`), its HANDOFF.md read and saved
// (`…/handoff`), and the cut-over (`…/cutover`). The calls the session
// menu's Super Compact… sheet (SuperCompact) makes.

import VisorProtocol

extension VisorAgentServer {
    public var superCompacts: Bool { true }

    public func superCompact(of session: String) async throws -> SuperCompactStatus? {
        do {
            return try Self.status(try await superCompactCall("GET", session, ""))
        } catch SuperCompactRefusal.none {
            return nil
        }
    }

    public func startSuperCompact(_ session: String) async throws -> SuperCompactStatus {
        try Self.status(try await superCompactCall("POST", session, ""))
    }

    public func cancelSuperCompact(_ session: String) async throws -> SuperCompactStatus {
        try Self.status(try await superCompactCall("DELETE", session, ""))
    }

    public func superCompactHandoff(of session: String) async throws -> String {
        let text = try await superCompactCall("GET", session, "/handoff")
        guard let reply = Envelope.decode(text, defaultType: "handoff"), let handoff = reply.text else {
            throw AgentServerError.message("No HANDOFF.md came back")
        }
        return handoff
    }

    public func saveSuperCompactHandoff(of session: String, text: String) async throws -> SuperCompactStatus {
        var body = Envelope(type: "handoff")
        body.text = text
        return try Self.status(try await superCompactCall("PUT", session, "/handoff", body: body.encoded()))
    }

    public func superCompactCutover(_ session: String) async throws -> (session: String, sessions: [SessionInfo]) {
        let text = try await superCompactCall("POST", session, "/cutover")
        guard let reply = Envelope.decode(text, defaultType: "cutover"), let started = reply.session else {
            throw AgentServerError.message("No new session came back")
        }
        return (started, reply.sessions ?? [])
    }

    /// Why a call came back without a job: the session has had none.
    private enum SuperCompactRefusal: Error { case none }

    private static func status(_ text: String) throws -> SuperCompactStatus {
        guard let value = parseJSON(text), let status = SuperCompactStatus(json: value) else {
            throw AgentServerError.message("The super compact's status could not be read")
        }
        return status
    }

    /// One call, its refusal said in the server's own words: a session with
    /// no job is `SuperCompactRefusal.none`, and a server from before
    /// Super Compact says so.
    private func superCompactCall(_ method: String, _ session: String, _ step: String, body: String = "") async throws -> String {
        do {
            return try await callText(method, "/sessions/" + Self.escape(session) + "/super-compact" + step, body: body)
        } catch {
            let text = "\(error)"
            // "HTTP 404: {…}": the envelope after the status says why. A
            // bare "not found" is a route the server doesn't have.
            if text.hasPrefix("HTTP 404"), text.contains("\"error\":\"not found\"") {
                throw AgentServerError.message("This computer's Visor Server is too old for Super Compact: update it.")
            }
            if method == "GET", step.isEmpty, text.hasPrefix("HTTP 404") { throw SuperCompactRefusal.none }
            if let start = text.firstIndex(of: "{"), let reply = Envelope.decode(String(text[start...]), defaultType: "reply"),
               let said = reply.message ?? reply.error {
                throw AgentServerError.message(said)
            }
            throw error
        }
    }
}
