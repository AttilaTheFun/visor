// A server's own controls, as its owner's menu and Settings use them over
// REST (docs/protocol.md, "The server's own settings"): what Visor on the
// Mac asks of its own server, at its socket file, in the app's process or
// the server agent's. Every one is an admin's call; the reset of the admin
// token and an emergency rotation of the signing keys are taken from
// Visor.app's own connection alone (its app key, which the host's socket
// file service shows).

import VisorProtocol
import VisorServices

extension VisorAgentServer {
    /// How the server stands, and its settings (`GET /api/settings`).
    public func controls() async throws -> ServerControls {
        try Self.controls(from: try await callText("GET", "/settings", body: ""))
    }

    /// Changes the fields given (`PUT /api/settings`): how it stands now.
    public func change(_ change: ServerControlsChange) async throws -> ServerControls {
        try Self.controls(from: try await callText("PUT", "/settings", body: change.json.encoded()))
    }

    /// Every session as a markdown table (`GET /api/session-table`).
    public func sessionTable() async throws -> String {
        guard let text = parseJSON(try await callText("GET", "/session-table", body: ""))?["text"].string else {
            throw AgentServerError.message("No session table")
        }
        return text
    }

    /// The first admin token, shown this once (`POST /api/admin-token`);
    /// refused while there is one.
    public func createAdminToken() async throws -> String {
        try Self.token(from: try await callText("POST", "/admin-token", body: ""))
    }

    /// A new admin token without the current one, shown this once
    /// (`POST /api/admin-token/reset`): Visor.app's menu's alone.
    public func resetAdminToken() async throws -> String {
        try Self.token(from: try await callText("POST", "/admin-token/reset", body: ""))
    }

    /// A new signing key; in an emergency every other dropped, and every
    /// agent's token with it (`POST /api/keys/rotate`).
    public func rotateSigningKeys(emergency: Bool) async throws {
        let body = emergency ? JSONValue.object(["dropPrevious": .bool(true)]).encoded() : ""
        _ = try await callText("POST", "/keys/rotate", body: body)
    }

    /// The APNs key set (`POST /api/push/key`).
    public func setPushKey(pem: String, keyID: String, teamID: String) async throws {
        let body = JSONValue.object(["key": .string(pem), "keyID": .string(keyID), "teamID": .string(teamID)]).encoded()
        _ = try await callText("POST", "/push/key", body: body)
    }

    /// A test push to every device (`POST /api/push/test`).
    public func sendTestPush() async throws {
        _ = try await callText("POST", "/push/test", body: "")
    }

    /// Stops the server (`POST /api/quit`): its agents ended, then it.
    public func quitServer() async throws {
        _ = try await callText("POST", "/quit", body: "")
    }

    /// Restarts the server (`POST /api/restart`), into the build at `path`
    /// when one is given.
    public func restartServer(installing path: String?) async throws {
        var body: [String: JSONValue] = [:]
        if let path { body["path"] = .string(path) }
        _ = try await callText("POST", "/restart", body: JSONValue.object(body).encoded())
    }

    /// What a call refused says, for the person who asked: the server's
    /// own words where it gave them.
    public static func problem(_ error: Error) -> String {
        if let body = VisorHost.http?.body(of: error), let words = Self.said(body) { return words }
        if let refused = error as? AgentServerError, case .message(let said) = refused { return said }
        return "\(error)"
    }

    static func controls(from text: String) throws -> ServerControls {
        guard let json = parseJSON(text), let controls = ServerControls(json: json) else {
            throw AgentServerError.message(Self.said(text) ?? "The server said nothing of its settings")
        }
        return controls
    }

    /// What an answer says went wrong: an error envelope's `message`, or
    /// a plain `error`.
    static func said(_ text: String) -> String? {
        guard let answer = Envelope.decode(text, defaultType: "reply") else { return nil }
        if let message = answer.message, !message.isEmpty { return message }
        if let error = answer.error, !error.isEmpty { return error }
        return nil
    }

    static func token(from text: String) throws -> String {
        guard let token = parseJSON(text)?["token"].string, !token.isEmpty else { throw AgentServerError.message("No token came back") }
        return token
    }
}
