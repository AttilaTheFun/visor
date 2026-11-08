// A turn the server handed an agent about its mail (docs/agent-mail.md),
// told apart from the person's own words by its form, and the words its
// mail row in the chat shows instead (AgentUI's MailRow, a tool row named
// "mail"): the notice that messages wait unread, and the message itself as
// an agent whose MCP server has no read_inbox is still handed it, headed
// with its sender.

enum MailTurn {
    static let noticeStart = "[Visor: you have "
    static let noticeEnd = " in your inbox; read them with read_inbox]"
    static let messageStart = "[Message from the Visor session “"

    /// The mail row's words for a turn of the user's, or nil for the
    /// person's own.
    static func row(for text: String) -> String? {
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
}
