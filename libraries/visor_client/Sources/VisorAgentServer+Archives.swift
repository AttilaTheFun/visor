// A session exported as a session archive and one imported into the
// server's backups store (`POST /api/sessions/<id>/export`,
// `POST /api/import`; docs/protocol.md, "Session archive v1"): the calls
// SessionExport and SessionImport make. The archive itself is read as a
// move's file is (migrationRead).

import VisorProtocol

extension VisorAgentServer {
    public var archives: Bool { true }

    public func exportSession(_ session: String) async throws -> (token: String, file: MigrationFile) {
        let reply = try await archiveCall("/sessions/" + session + "/export", Envelope(type: "export"))
        guard let token = reply.migration, let file = reply.file else { throw AgentServerError.message("No archive came back") }
        return (token, file)
    }

    public func importUpload(size: Int, name: String) async throws -> String {
        var body = Envelope(type: "import")
        body.file = MigrationFile(id: "archive", place: name, size: size, packed: true)
        guard let token = try await archiveCall("/import", body).migration else { throw AgentServerError.message("The import was not begun") }
        return token
    }

    public func importWrite(_ token: String, offset: Int, data: String) async throws -> Int {
        var body = Envelope(type: "import")
        body.migration = token
        body.offset = offset
        body.data = data
        guard let next = try await archiveCall("/import/write", body).offset else { throw AgentServerError.message("Nothing was written") }
        return next
    }

    public func importFinish(_ token: String) async throws -> SessionBackup {
        var body = Envelope(type: "import")
        body.migration = token
        guard let backup = try await archiveCall("/import/finish", body).backup else { throw AgentServerError.message("Nothing was imported") }
        return backup
    }

    /// One call, its refusal said in the server's own words; a server from
    /// before session archives says so.
    private func archiveCall(_ path: String, _ body: Envelope) async throws -> Envelope {
        do {
            let reply = try await call("POST", path, body)
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
            if text.contains("404") { throw AgentServerError.message("This computer's Visor Server is too old for session archives: update it.") }
            throw error
        }
    }
}
