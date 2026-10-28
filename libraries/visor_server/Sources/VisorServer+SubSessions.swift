// Sub-sessions (docs/sub-sessions.md): a session's forks and branches,
// sessions of their own made from its conversation, and its side
// questions (`/btw`), answered beside the conversation without going into
// it.

import Foundation
import VisorProtocol

extension VisorServer {
    /// `fork`: a fork or branch of `parent`, on the parent's folder,
    /// computer or container, agent, model and permissions, its
    /// conversation the parent's (up to `at`). Its agent makes its own
    /// copy when it starts, with the prompt when there is one (a fork's),
    /// else with the first thing the person says (a branch's).
    func performFork(_ envelope: Envelope, from client: ClientConnection?) {
        guard let parent = session(envelope.parent ?? envelope.session) else {
            client?.send(.error("There is no such session to fork."))
            return
        }
        guard let from = parent.process.resumeID else {
            client?.send(.error("Nothing to fork yet: \(parent.displayName) has not begun its conversation."))
            return
        }
        let origin = envelope.origin ?? .fork
        let id = envelope.id ?? UUID().uuidString
        let given = (envelope.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var info = SessionInfo(id: id, agent: parent.info.agent, cwd: parent.info.cwd,
                               title: given.isEmpty ? Self.subSessionTitle(origin, of: parent.displayName) : String(given.prefix(60)),
                               skipPermissions: parent.info.skipPermissions, model: parent.info.model, effort: parent.info.effort,
                               created: Date().timeIntervalSince1970)
        info.parent = parent.info.id
        info.origin = origin
        // Its agent runs where the parent's does: in a container, the same
        // one, which holds the parent's conversation.
        info.container = parent.info.container
        let past = Self.rows(parent.entries, through: envelope.at)
        let record = SessionRecord(info: info, process: makeProcess(info, resume: from), entries: past)
        guard record.startFork(PendingFork(from: from, at: envelope.at)) else {
            client?.send(.error("\(parent.info.agent.title) cannot fork a conversation."))
            return
        }
        record.refreshResume()
        sessions.append(record)
        if let client { record.subscribers.insert(ObjectIdentifier(client)) }
        Self.log("session \(origin.rawValue)ed: \(info.title) from \(parent.displayName)")
        saveArchive()
        broadcastSessions()
        let prompt = (envelope.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { deliver(prompt, to: record) }
    }

    /// What a fork or branch is called until it is named.
    static func subSessionTitle(_ origin: SessionOrigin, of parent: String) -> String {
        switch origin {
        case .fork: "Fork of \(parent)"
        case .branch: "Branch of \(parent)"
        }
    }

    /// A conversation's rows up to and including `id` (all of them when
    /// it is nil, or not among them).
    static func rows(_ rows: [TranscriptEntry], through id: String?) -> [TranscriptEntry] {
        guard let id, let index = rows.firstIndex(where: { $0.id == id }) else { return rows }
        return Array(rows[...index])
    }

    /// `side`: a side question about a session's conversation, asked of
    /// its agent beside the conversation, and answered on the session's
    /// `side` for every client to see.
    func performSide(_ envelope: Envelope) {
        guard let record = session(envelope.session) else { return }
        let question = (envelope.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        ask(question, id: envelope.id ?? UUID().uuidString, of: record)
    }

    func ask(_ question: String, id: String, of record: SessionRecord) {
        guard !record.info.side.contains(where: { $0.id == id }) else { return }
        let earlier = record.info.side
        record.info.side.append(SideQuestion(id: id, question: question, asked: Date().timeIntervalSince1970))
        broadcastSessions()
        // Its agent heard from: one started for the question is the
        // session's, as one started for a message is.
        if !record.isBound { bind(record) }
        let process = record.process
        Task {
            var answer: String?
            var failure: String?
            do {
                answer = try await process.askSide(question, after: earlier)
            } catch {
                failure = error.localizedDescription
            }
            // Ended meanwhile: nobody keeps the answer.
            guard let index = record.info.side.firstIndex(where: { $0.id == id }) else { return }
            record.info.side[index].answer = answer
            record.info.side[index].failure = failure
            saveArchive()
            broadcastSessions()
        }
    }

    /// `endSide`: the person is done with a session's side questions.
    func performEndSide(_ envelope: Envelope) {
        guard let record = session(envelope.session), !record.info.side.isEmpty else { return }
        record.info.side = []
        saveArchive()
        broadcastSessions()
    }

    /// What the person typed, when it is Visor's own sub-session command:
    /// `/btw <question>`, `/fork <prompt>`, `/branch [name]`. Handled here,
    /// for what reaches a session as words (an older client, another
    /// agent's message); a client of 0.43 sends them as their own messages
    /// and opens what they make.
    func performSubSessionCommand(_ text: String, on record: SessionRecord) -> Bool {
        guard let command = SubSessionCommand(text) else { return false }
        switch command {
        case .side(let question):
            // With no question there is nothing to ask: a client opens the
            // side questions for the person to ask one.
            if let question { ask(question, id: UUID().uuidString, of: record) }
        case .fork(let prompt):
            performFork(.fork(id: UUID().uuidString, parent: record.info.id, origin: .fork, text: prompt), from: nil)
        case .branch(let name):
            performFork(.fork(id: UUID().uuidString, parent: record.info.id, origin: .branch, title: name ?? ""), from: nil)
        }
        return true
    }
}
