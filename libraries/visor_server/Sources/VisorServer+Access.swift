// Who is let in: the password, and the tokens `hello` hands out; and
// where the password is kept.

import ClaudeTranscript
import MessageCache
import Foundation
import VisorProtocol

extension VisorServer {
    /// The password as kept: the system's place for secrets.
    static func keptPassword() -> String {
        secrets.get("password") ?? ""
    }

    /// Whether a request may be answered: it came on a trusted connection
    /// (the socket file, through SSH as this user); the server asks nothing
    /// and the front it sits behind (if it was told of one) vouches for it;
    /// or the bearer is the password, a token `hello` issued, or the admin
    /// token (AdminToken).
    ///
    /// Never an agent's token, a session's or a runner's agent's: those act
    /// as their own session over the socket's `agent` and
    /// `approval_request` (and a runner's agent over its driver stream),
    /// never over REST, whose every route is an admin's (VisorServer+REST:
    /// none is a session's own). The tools an agent runs that need the
    /// admin side (a deploy, a restart, a backup: docs/DEVELOPMENT.md) take
    /// the admin token from $VISOR_ADMIN_TOKEN, which Visor never gives an
    /// agent.
    func authorized(_ request: HTTPRequest) -> Bool {
        if request.trusted { return true }
        // An agent's token is refused even where nothing is asked.
        if isAgentToken(request.authorization) { return false }
        if settings.asksNothing { return front?.admits(request.headers) ?? true }
        guard let bearer = request.authorization, !bearer.isEmpty else { return false }
        return bearer == password || tokens.contains(bearer) || adminToken.admits(bearer)
    }

    /// The answer to a request that is not let in: it wants the password.
    /// It says whose computer this is (its id, as `hello` does), so a
    /// client that reached it at another computer's path knows the path
    /// is wrong rather than taking it for that computer asking. An agent's
    /// token is told it is not a REST credential.
    func refusal(_ request: HTTPRequest) -> HTTPResponse {
        if !request.trusted, isAgentToken(request.authorization) {
            return HTTPResponse(401, Envelope.error(Self.agentTokenRefusedOverREST).encoded())
        }
        return HTTPResponse(401, "{\"error\":\"wrong password\",\"id\":\"\(id)\"}")
    }

    /// What an agent's token shown to the REST side is told.
    static let agentTokenRefusedOverREST = "A session's token acts as its own session over Visor's socket, never over REST: "
        + "the REST side takes the password, or the admin token ($VISOR_ADMIN_TOKEN)."

    /// A token for the socket's login, for a client that `hello` let in;
    /// `byAdmin`, for one the admin token let in (or a token of these),
    /// which goes when the admin token is rotated or reset.
    func issueToken(byAdmin: Bool = false) -> String {
        let token = UUID().uuidString.lowercased()
        tokens.append(token)
        if byAdmin { adminHelloTokens.insert(token) }
        if tokens.count > 512 {
            for old in tokens.prefix(tokens.count - 512) { adminHelloTokens.remove(old) }
            tokens.removeFirst(tokens.count - 512)
        }
        return token
    }

    /// Whether `bearer` is the admin token, or a `hello` token handed out
    /// to it.
    func isAdminBearer(_ bearer: String?) -> Bool {
        adminToken.admits(bearer) || (bearer.map { adminHelloTokens.contains($0) } ?? false)
    }

    /// The `hello` tokens the admin token led to, gone (the admin token
    /// was rotated or reset): the old admin token's holder keeps nothing.
    func forgetAdminHelloTokens() {
        guard !adminHelloTokens.isEmpty else { return }
        tokens.removeAll { adminHelloTokens.contains($0) }
        Self.log("admin token replaced: the \(adminHelloTokens.count) hello token(s) handed out to it are gone")
        adminHelloTokens = []
    }

    /// Four short words, easy to type on a phone.
    public static func generatePassword() -> String {
        let words = ["amber", "birch", "cedar", "delta", "ember", "fjord", "grove", "heron", "iris", "jade", "kelp", "lumen", "maple", "north", "ocean", "pearl", "quill", "river", "stone", "tidal", "umber", "vale", "wren", "zephyr"]
        return (0..<4).map { _ in words.randomElement()! }.joined(separator: "-")
    }
}
