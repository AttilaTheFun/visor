/// A page pushed over a session's chat, on the stack in the window's
/// detail: one of its forks or branches (a session of its own), its side
/// questions, or one of its subagents. Back returns to the chat beneath.
enum SubSessionRoute: Hashable {
    case session(String)
    case side(String)
    case subagent(session: String, agent: String)
}
