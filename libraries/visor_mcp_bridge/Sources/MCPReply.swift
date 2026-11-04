/// What Visor's server answered a call about the other sessions: its text,
/// or why there is none (`ok` false: the server's error, or that it could
/// not be reached).
struct MCPReply: Equatable, Sendable {
    let ok: Bool
    let text: String
}
