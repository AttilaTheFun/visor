/// What Visor's server answered a call about the other sessions: its text,
/// or why there is none (`ok` false: the server's error, or that it could
/// not be reached).
package struct MCPReply: Equatable, Sendable {
    package let ok: Bool
    package let text: String

    package init(ok: Bool, text: String) {
        self.ok = ok
        self.text = text
    }
}
