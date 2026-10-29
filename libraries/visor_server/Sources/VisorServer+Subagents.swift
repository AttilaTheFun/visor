// A session's subagents (docs/sub-sessions.md): what its agent sent off
// with its Agent tool, read from the agent's own files (ClaudeSubagent), a
// row and a capsule each until the person closes it, its conversation on a
// page of its own; the person's words for one passed on by the session's
// agent while it runs, and once it has finished, its conversation gone on
// with as a session of its own.

import Foundation
import VisorProtocol

extension VisorServer {
    /// Reads the session's subagents again when the agent did something
    /// that may have changed them: sent one off, heard back from one, or
    /// changed what runs in the background; at most every two seconds
    /// while they work, and once more at the end of each turn.
    func noteSubagents(after event: AgentEvent, of record: SessionRecord) {
        switch event {
        case .toolStarted(let call, let name, _, _) where TurnStatus.kind(of: name) == .subagent:
            record.subagentCalls.insert(call)
            // Its files are written a moment after the call.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                refreshSubagents(of: record)
            }
        case .subagents:
            if let read = record.subagentsRead, ContinuousClock.now - read < .seconds(2) { return }
            refreshSubagents(of: record)
        case .background, .toolFinished:
            guard !record.watchedSubagents.isEmpty || record.info.background.contains(where: { $0.kind == .subagent }) else { return }
            refreshSubagents(of: record)
        case .busy(false):
            guard !record.watchedSubagents.isEmpty else { return }
            refreshSubagents(of: record)
        default:
            return
        }
    }

    /// The session's subagents as its agent's files have them: each one
    /// running, and each seen running here, until the person closes it.
    func refreshSubagents(of record: SessionRecord) {
        record.subagentsRead = .now
        guard record.pendingFork == nil, let id = record.process.resumeID,
              let harness = harnesses.harness(for: record.info.agent) else { return }
        let all = harness.subagents(id: id, cwd: record.info.cwd)
        for agent in all where agent.running || agent.call.map(record.subagentCalls.contains) == true {
            record.watchedSubagents.insert(agent.id)
        }
        let shown = all.filter { !record.closedSubagents.contains($0.id) && record.watchedSubagents.contains($0.id) }
        guard shown != record.info.subagents else { return }
        record.info.subagents = shown
        saveArchive()
        broadcastSessions()
    }

    /// `GET /sessions/{id}/subagents/{agent}`: a subagent's conversation.
    func subagentTranscript(of record: SessionRecord, agent: String) -> [TranscriptEntry] {
        guard let id = record.process.resumeID, let harness = harnesses.harness(for: record.info.agent) else { return [] }
        return harness.subagentTranscript(id: id, cwd: record.info.cwd, subagent: agent)
    }

    /// `toSubagent`: the person's words for a subagent, handed to the
    /// session's agent to pass on with its SendMessage, as it alone reaches
    /// a subagent that is running.
    func performToSubagent(_ envelope: Envelope, from client: ClientConnection?) {
        guard let record = session(envelope.session), let agent = envelope.id,
              let subagent = record.info.subagents.first(where: { $0.id == agent }) else { return }
        let words = (envelope.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        guard subagent.running else {
            client?.send(.error("\(subagent.description.isEmpty ? "That subagent" : subagent.description) has finished."))
            return
        }
        deliver(Self.wordsForSubagent(words, to: subagent), to: record)
    }

    /// What the session's agent is handed for one of its subagents.
    static func wordsForSubagent(_ words: String, to subagent: SubagentInfo) -> String {
        let named = subagent.description.isEmpty ? "your subagent" : "your subagent \u{201C}\(subagent.description)\u{201D}"
        return "For \(named) (agent id \(subagent.id)), from me: pass this on to it with SendMessage, as it is, and go on with what you were doing.\n\n\(words)"
    }

    /// `fork` with the `subagent` origin: a finished subagent's
    /// conversation gone on with as a session of its own, under the
    /// session that sent it off and in place of the subagent's row; with
    /// `text`, said to it at once.
    func continueSubagent(_ envelope: Envelope, of parent: SessionRecord, from client: ClientConnection?) {
        guard let from = parent.process.resumeID, let agent = envelope.subagent,
              let harness = harnesses.harness(for: parent.info.agent),
              let subagent = harness.subagents(id: from, cwd: parent.info.cwd).first(where: { $0.id == agent }) else {
            client?.send(.error("There is no such subagent to go on with."))
            return
        }
        let name = subagent.description.isEmpty ? "That subagent" : subagent.description
        guard !subagent.running else {
            client?.send(.error("\(name) is still working: message it through \(parent.info.agent.title)."))
            return
        }
        guard let resume = harness.continueSubagent(id: from, cwd: parent.info.cwd, subagent: agent) else {
            client?.send(.error("\(parent.info.agent.title) can't go on with \(name) as a session of its own."))
            return
        }
        let id = envelope.id ?? UUID().uuidString
        let given = (envelope.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = given.isEmpty ? subagent.description : given
        var info = SessionInfo(id: id, agent: parent.info.agent, cwd: parent.info.cwd,
                               title: title.isEmpty ? Self.subSessionTitle(.subagent, of: parent.displayName) : String(title.prefix(60)),
                               skipPermissions: parent.info.skipPermissions, model: parent.info.model, effort: parent.info.effort,
                               created: Date().timeIntervalSince1970)
        info.parent = parent.info.id
        info.origin = .subagent
        info.container = parent.info.container
        let past = harness.subagentTranscript(id: from, cwd: parent.info.cwd, subagent: agent)
        let record = SessionRecord(info: info, process: makeProcess(info, resume: resume), entries: past)
        record.refreshResume()
        sessions.append(record)
        if let client { record.subscribers.insert(ObjectIdentifier(client)) }
        // The session's row stands for it from now on.
        parent.closedSubagents.insert(agent)
        parent.info.subagents.removeAll { $0.id == agent }
        Self.log("session from a subagent: \(info.title) of \(parent.displayName)")
        saveArchive()
        broadcastSessions()
        let words = (envelope.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { deliver(words, to: record) }
    }

    /// `closeSubagent`: the person is done with a subagent's row.
    func performCloseSubagent(_ envelope: Envelope) {
        guard let record = session(envelope.session), let agent = envelope.id else { return }
        record.closedSubagents.insert(agent)
        record.info.subagents.removeAll { $0.id == agent }
        saveArchive()
        broadcastSessions()
    }
}
