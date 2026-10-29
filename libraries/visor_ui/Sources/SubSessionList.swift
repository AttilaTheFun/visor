import AgentUI
import VisorProtocol

/// A session's sub-sessions as AgentUI shows them: a row each above its
/// composer, a capsule each under its card. Its forks and branches still
/// going, then its side questions while it has any.
enum SubSessionList {
    /// The id its side questions go by among the rows, and what a
    /// subagent's id is put after.
    static let sideID = "side"
    static let subagentPrefix = "subagent:"

    static func items(of info: SessionInfo?, children: [SessionInfo]) -> [SubSession] {
        var items = children.sorted { $0.created < $1.created }.map { child in
            SubSession(id: child.id, kind: child.origin == .branch ? .branch : .fork, title: child.title.isEmpty ? child.agent.title : child.title,
                       detail: child.preview, working: child.busy)
        }
        items += (info?.subagents ?? []).map { agent in
            SubSession(id: subagentPrefix + agent.id, kind: .subagent, title: agent.description.isEmpty ? agent.type : agent.description,
                       detail: agent.running ? (agent.type.isEmpty ? "Working" : agent.type) : "Finished", working: agent.running)
        }
        if let latest = info?.side.last {
            let detail = latest.answer ?? latest.failure ?? "Thinking…"
            items.append(SubSession(id: sideID, kind: .side, title: latest.question, detail: Self.line(detail), working: !latest.settled))
        }
        return items
    }

    /// What opening one shows: a fork or branch is a session of its own.
    static func selection(of item: SubSession, under session: SessionSelection) -> ContentSelection {
        if item.id == sideID { return .side(session) }
        if item.id.hasPrefix(subagentPrefix) { return .subagent(session, String(item.id.dropFirst(subagentPrefix.count))) }
        return .session(SessionSelection(serverID: session.serverID, sessionID: item.id))
    }

    /// The first line of an answer, for a row of one line.
    static func line(_ text: String) -> String {
        String(text.split(separator: "\n", omittingEmptySubsequences: true).first ?? "")
    }
}
