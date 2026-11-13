// Who is let in: the password, and the tokens `hello` hands out; and
// where the password is kept.

import ClaudeTranscript
import MessageCache
import Foundation
import VisorProtocol

extension VisorServer {
    /// The agents' token as kept, made the first time.
    static func keptAgentToken() -> String {
        if let kept = secrets.get("agentToken"), !kept.isEmpty { return kept }
        let made = UUID().uuidString
        secrets.set("agentToken", made)
        return made
    }

    /// The password as kept: the system's place for secrets.
    static func keptPassword() -> String {
        secrets.get("password") ?? ""
    }

    /// Whether a request may be answered: it came on a trusted connection
    /// (the socket file, through SSH as this user); the server asks nothing
    /// and the front it sits behind (if it was told of one) vouches for it;
    /// or the bearer is the password or a token `hello` issued.
    func authorized(_ request: HTTPRequest) -> Bool {
        if request.trusted { return true }
        if settings.asksNothing { return front?.admits(request.headers) ?? true }
        guard let bearer = request.authorization, !bearer.isEmpty else { return false }
        // The agent token too: the agents this server started (and the
        // tools they run, such as a deploy) hold it, and no one else.
        return bearer == password || tokens.contains(bearer) || bearer == agentToken
    }

    /// The answer to a request that is not let in: it wants the password.
    /// It says whose computer this is (its id, as `hello` does), so a
    /// client that reached it at another computer's path knows the path
    /// is wrong rather than taking it for that computer asking.
    func refusal(_ request: HTTPRequest) -> HTTPResponse {
        HTTPResponse(401, "{\"error\":\"wrong password\",\"id\":\"\(id)\"}")
    }

    /// A token for the socket's login, for a client that `hello` let in.
    func issueToken() -> String {
        let token = UUID().uuidString.lowercased()
        tokens.append(token)
        if tokens.count > 512 { tokens.removeFirst(tokens.count - 512) }
        return token
    }

    /// Four short words, easy to type on a phone.
    public static func generatePassword() -> String {
        let words = ["amber", "birch", "cedar", "delta", "ember", "fjord", "grove", "heron", "iris", "jade", "kelp", "lumen", "maple", "north", "ocean", "pearl", "quill", "river", "stone", "tidal", "umber", "vale", "wren", "zephyr"]
        return (0..<4).map { _ in words.randomElement()! }.joined(separator: "-")
    }
}
