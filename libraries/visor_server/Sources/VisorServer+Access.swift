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
        if trusts(socketFile: request.trusted, headers: request.headers) { return true }
        // An agent's token is refused even where nothing is asked.
        if isAgentToken(request.authorization) { return false }
        if settings.asksNothing { return front?.admits(request.headers) ?? true }
        guard let bearer = request.authorization, !bearer.isEmpty else { return false }
        return bearer == password || tokens.contains(bearer) || adminToken.admits(bearer)
    }

    /// Whether a connection on the socket file is let in as this user,
    /// without a password: while SSH clients are (`sshEnabled`), and always
    /// for Visor.app on this computer (`isOwnApp`). One on the port never is.
    func trusts(socketFile: Bool, headers: [String: String]) -> Bool {
        socketFile && (settings.sshEnabled || isOwnApp(socketFile: socketFile, headers: headers))
    }

    /// Whether a connection is Visor.app's own, on this computer: on the
    /// socket file, showing the app key (`appKey`), which the keychain
    /// gives Visor's processes alone. Its menu's calls are taken from it
    /// alone: the admin token reset without it, an emergency rotation of
    /// the signing keys; and, with SSH clients off, every call of its own.
    ///
    /// A call there that doesn't show it has the key asked again
    /// (`appKeyAskedAgain`, at most every `appKeyAskInterval`): a key
    /// another process of Visor's kept since is taken, and with none kept
    /// this one is kept again, for the app's next call (AppKeyKeeper).
    func isOwnApp(socketFile: Bool, headers: [String: String]) -> Bool {
        guard socketFile, appKey != nil else { return false }
        if SecretToken.same(headers[Self.appKeyHeader], appKey) { return true }
        guard let askAgain = appKeyAskedAgain,
              appKeyLastAsked.map({ Date().timeIntervalSince($0) >= Self.appKeyAskInterval }) ?? true else { return false }
        appKeyLastAsked = Date()
        guard let kept = askAgain(appKey) else { return false }
        appKey = kept
        return SecretToken.same(headers[Self.appKeyHeader], appKey)
    }

    /// How often, at most, the app key is asked again: seconds.
    nonisolated static let appKeyAskInterval: TimeInterval = 5

    func isOwnApp(_ request: HTTPRequest) -> Bool { isOwnApp(socketFile: request.trusted, headers: request.headers) }

    /// The header the app key is shown in (lower-cased, as headers are read).
    nonisolated public static let appKeyHeader = "x-visor-app-key"

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
