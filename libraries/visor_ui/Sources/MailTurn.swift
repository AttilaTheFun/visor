// A turn the server handed an agent about its mail (docs/agent-mail.md),
// told apart from the person's own words by its form, and the words its
// mail row in the chat shows instead (AgentUI's MailRow, a tool row named
// "mail"): the notice that messages wait unread, and the message itself as
// an agent whose MCP server has no read_inbox is still handed it, headed
// with its sender.

import VisorProtocol

enum MailTurn {
    static let noticeStart = "[Visor: you have "
    static let noticeEnd = " in your inbox; read them with read_inbox]"
    static let messageStart = "[Message from the Visor session “"

    /// The mail row's words for a turn of the user's, or nil for the
    /// person's own.
    static func row(for text: String) -> String? {
        // A message another session wrote (AgentMessageMarkers).
        if let message = AgentMessageMarkers.inbound(text) {
            return "From \(message.session) on \(message.computer): " + message.body
        }
        if text.hasPrefix(noticeStart), text.hasSuffix(noticeEnd) {
            let count = text.dropFirst(noticeStart.count).dropLast(noticeEnd.count)
            return "\(count) in its inbox: its agent was told"
        }
        // The standard library's own search, not Foundation's: Visor on
        // the web has no NSString bridge to lean on.
        guard text.hasPrefix(messageStart), let close = text.firstRange(of: "]\n\n") else { return nil }
        let header = text[text.index(text.startIndex, offsetBy: messageStart.count)..<close.lowerBound]
        let body = text[close.upperBound...]
        // “<name>” (<id>) on <computer> (server <id>), to this session …
        guard let nameEnd = header.firstRange(of: "”") else { return nil }
        let name = header[..<nameEnd.lowerBound]
        let rest = header[nameEnd.upperBound...]
        var computer = ""
        if let on = rest.firstRange(of: ") on "), let server = rest[on.upperBound...].firstRange(of: " (server ") {
            computer = String(rest[on.upperBound..<server.lowerBound])
        }
        return "From \(name)" + (computer.isEmpty ? "" : " on \(computer)") + ": " + body
    }

    /// The mail row's words for an agent's reply that is a message to
    /// another session (AgentMessageMarkers), or nil for any other reply.
    static func sentRow(for text: String) -> String? {
        AgentMessageMarkers.outbound(text).map { "To \($0.session) on \($0.computer): " + $0.body }
    }
}
