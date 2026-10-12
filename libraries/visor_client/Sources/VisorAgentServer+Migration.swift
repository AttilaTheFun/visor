// Moving a session between Visor servers (`POST /api/migration/<step>`;
// docs/protocol.md): the calls SessionMigration makes of each side.

import VisorProtocol

extension VisorAgentServer {
    public var migrates: Bool { true }

    public func migrationOffer(for session: String) async throws -> MigrationOffer {
        var body = Envelope(type: "migration")
        body.session = session
        guard let offer = try await step("offer", body).offer else { throw AgentServerError.message("No offer came back") }
        return offer
    }

    public func migrationRead(_ offer: String, file: String, offset: Int, length: Int) async throws -> (data: String, next: Int) {
        var body = Envelope(type: "migration")
        body.migration = offer
        body.file = MigrationFile(id: file, place: "", size: length, packed: false)
        body.offset = offset
        let reply = try await step("read", body)
        guard let data = reply.data, let next = reply.offset else { throw AgentServerError.message("Nothing was read") }
        return (data, next)
    }

    public func migrationPack(_ offer: String, project: String) async throws -> MigrationFile {
        var body = Envelope(type: "migration")
        body.migration = offer
        body.path = project
        guard let file = try await step("pack", body).file else { throw AgentServerError.message("Nothing was packed") }
        return file
    }

    public func migrationPlan(for offer: MigrationOffer) async throws -> MigrationPlan {
        var body = Envelope(type: "migration")
        body.offer = offer
        guard let plan = try await step("plan", body).plan else { throw AgentServerError.message("No plan came back") }
        return plan
    }

    public func migrationWrite(_ plan: String, file: String, offset: Int, data: String) async throws {
        var body = Envelope(type: "migration")
        body.migration = plan
        body.file = MigrationFile(id: file, place: "", size: 0, packed: false)
        body.offset = offset
        body.data = data
        _ = try await step("write", body)
    }

    public func migrationClone(_ plan: String, step chosen: MigrationStep) async throws {
        var body = Envelope(type: "migration")
        body.migration = plan
        body.steps = [chosen]
        _ = try await step("clone", body)
    }

    public func migrationUnpack(_ plan: String, file: String, step chosen: MigrationStep) async throws {
        var body = Envelope(type: "migration")
        body.migration = plan
        body.file = MigrationFile(id: file, place: "", size: 0, packed: true)
        body.steps = [chosen]
        _ = try await step("unpack", body)
    }

    public func migrationFinish(_ plan: String, steps: [MigrationStep], cwd: String?) async throws -> (session: String, sessions: [SessionInfo]) {
        var body = Envelope(type: "migration")
        body.migration = plan
        body.steps = steps
        body.cwd = cwd
        let reply = try await step("finish", body)
        guard let session = reply.session else { throw AgentServerError.message("No session was started") }
        return (session, reply.sessions ?? [])
    }

    /// One step, its refusal said in the server's own words.
    private func step(_ name: String, _ body: Envelope) async throws -> Envelope {
        do {
            let reply = try await call("POST", "/migration/" + name, body)
            if reply.type == "error" { throw AgentServerError.message(reply.message ?? reply.error ?? "The server refused") }
            return reply
        } catch let error as AgentServerError {
            throw error
        } catch {
            // "HTTP 400: {…}": the envelope after the status says why.
            let text = "\(error)"
            if let start = text.firstIndex(of: "{"), let reply = Envelope.decode(String(text[start...]), defaultType: "reply"),
               let said = reply.message ?? reply.error {
                throw AgentServerError.message(said)
            }
            throw error
        }
    }
}
