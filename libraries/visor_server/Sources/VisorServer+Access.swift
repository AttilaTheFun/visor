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
    /// or the bearer is the password, a token `hello` issued, or an
    /// agent's token.
    func authorized(_ request: HTTPRequest) -> Bool {
        if request.trusted { return true }
        if settings.asksNothing { return front?.admits(request.headers) ?? true }
        guard let bearer = request.authorization, !bearer.isEmpty else { return false }
        // An agent's token too: the agents this server started (and the
        // tools they run, such as a deploy, a restart or a backup:
        // docs/DEVELOPMENT.md) hold their session's, and no one else.
        // Logan (2026-11-14): sessions running natively may use the admin
        // side; those in a container may not, so a runner's agent token
        // (agent_protocol's) is never let in here.
        return bearer == password || tokens.contains(bearer) || isAgentToken(bearer)
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
