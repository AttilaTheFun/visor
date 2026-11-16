// What a driven session's agent asks of the other sessions, through its
// wrapper's MCP relay and this server's driver (VisorDriver's DrivenMCP):
// the asks a session's own MCP server makes here (VisorServer+AgentAsks),
// as that session. Its driver has already told it by its token (Job.token)
// which session it is, so it presents none of its own: the ask goes
// straight to the caller-based path (answerAgent(_:caller:reply:)). A
// runner's agent is never given a session token, which would be a REST
// credential (VisorServer+Access.swift).

import Foundation
import VisorProtocol

extension VisorServer {
    /// `fields` (an `agent` request's: `mode`, `session`, `server`, `text`,
    /// …) asked as the agent of the driven session `session`: the reply's
    /// text, or why there is none (`ok` false).
    package func answerDrivenAgent(_ session: String, fields: [String: JSONValue]) async -> (ok: Bool, text: String) {
        guard let record = self.session(session), record.driven else {
            return (false, "This session's agent isn't one this server drives.")
        }
        var message = fields
        message["type"] = .string("agent")
        message.removeValue(forKey: "token")
        message["client"] = .string(record.info.id)
        message["id"] = .string(UUID().uuidString.lowercased())
        guard let envelope = Envelope.decode(JSONValue.object(message).encoded()) else { return (false, "The ask couldn't be read.") }
        let once = DrivenAskReply()
        return await withCheckedContinuation { continuation in
            once.continuation = continuation
            answerAgent(envelope, caller: record) { reply in
                if let error = reply.error, !error.isEmpty {
                    once.give((false, error))
                } else {
                    once.give((true, reply.text ?? ""))
                }
            }
        }
    }
}

/// An ask's reply, given once however often its answer comes.
@MainActor
private final class DrivenAskReply {
    var continuation: CheckedContinuation<(ok: Bool, text: String), Never>?

    func give(_ reply: (ok: Bool, text: String)) {
        continuation?.resume(returning: reply)
        continuation = nil
    }
}
