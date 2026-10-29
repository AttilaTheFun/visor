// A session's sub-sessions (docs/sub-sessions.md): its forks and
// branches, sessions of their own made from its conversation, and its
// side questions (`/btw`).

import VisorProtocol

extension AgentServerConnection {
    /// A fork or branch of a session: up to `at` (a row's id) for a
    /// branch, started on `prompt` when there is one, named `title` when it
    /// is given. Its id once the server has it, subscribed, for the page to
    /// open; what went wrong is thrown, and kept for the UI.
    @discardableResult
    public func fork(_ sessionID: String, origin: SessionOrigin, at: String? = nil, prompt: String? = nil,
                     title: String? = nil) async throws -> String {
        let id = AgentServerRecord.newID()
        let prompt = prompt.map(Self.trimmed).flatMap { $0.isEmpty ? nil : $0 }
        do {
            let list = try await server.act(.fork(id: id, origin: origin, at: at, prompt: prompt, title: title.map(Self.trimmed)), on: sessionID)
            take(list, replacing: false)
        } catch {
            commandError = "\(error)"
            throw error
        }
        subscribe(id)
        return id
    }

    /// A side question about a session's conversation: answered on its
    /// `side`, without going into the conversation.
    public func askSide(_ sessionID: String, question: String) {
        let question = Self.trimmed(question)
        guard !question.isEmpty else { return }
        act(.side(id: AgentServerRecord.newID(), question: question), on: sessionID)
    }

    /// The person is done with a session's side questions.
    public func endSide(_ sessionID: String) { act(.endSide, on: sessionID) }

    /// The person's words for one of a session's subagents, passed on by
    /// the session's agent while the subagent runs.
    public func messageSubagent(_ sessionID: String, agent: String, text: String) {
        let text = Self.trimmed(text)
        guard !text.isEmpty else { return }
        act(.toSubagent(id: agent, text: text), on: sessionID)
    }

    /// The person is done with one of a session's subagents.
    public func closeSubagent(_ sessionID: String, agent: String) { act(.closeSubagent(id: agent), on: sessionID) }

    /// One of a session's subagents' conversation, as it stands now.
    public func subagentTranscript(_ sessionID: String, agent: String) async -> [TranscriptEntry]? {
        try? await server.subagentTranscript(of: sessionID, agent: agent)
    }

    /// The forks and branches of a session that are still going.
    public func children(of sessionID: String) -> [SessionInfo] {
        activeSessions.filter { $0.parent == sessionID }
    }

    /// A fork or branch whose parent is here to list it under itself.
    func isUnderParent(_ info: SessionInfo) -> Bool {
        guard let parent = info.parent else { return false }
        return activeSessions.contains { $0.id == parent }
    }
}
