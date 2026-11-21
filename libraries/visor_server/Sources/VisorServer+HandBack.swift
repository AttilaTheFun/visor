// A driven session moving back with its conversation (agent_protocol's
// DriverMessage.hand_back): its runner's agent is asked to end and return
// what it said there, so the turns it took on the runner come back with it.
// Asked only of a wrapper that said protocol 2 or more in its hello
// (HandingBackProcess); an older one is told to stop, as before, and the
// session carries on here from where it was before it moved, saying its
// turns on the runner weren't returned.
//
// The move back waits up to handBackWait (2 minutes) for the return to
// begin, and, once it has, up to handBackReceiveWait (5 minutes, the
// wrapper's own deadline) for it to end. Its files are staged and checked
// as they come (ReturnedConversationIntake, VisorDriver's DriverService),
// then put in place here on the main actor, so a move back that has given
// up meanwhile is never written to: the session resumes natively on the
// returned session id, under the key of the folder it moves back to.
// Refused, failed or too late, the session carries on as an older
// wrapper's would.

import ClaudeTranscript
import Foundation
import VisorAgent
import VisorProtocol

extension VisorServer {
    /// The runner's agent of `record` asked to hand its session back, and
    /// the move back finished once its conversation has come, or once it
    /// is given up on.
    func startHandBack(_ record: SessionRecord, _ process: HandingBackProcess, resume: String, cwd: String, why: String, loud: Bool) {
        let id = record.info.id
        var pending = PendingHandBack(agent: record.move?.agent ?? "", resume: resume, cwd: cwd, why: why, loud: loud)
        pending.timeout = handBackTimeout(id, after: handBackWait)
        handingBack[id] = pending
        setAgentState(record, .stopping)
        process.handBack()
        Self.log("moving \(record.info.title) (\(id)) back to this computer: its runner's agent \(pending.agent) asked to return its conversation")
        broadcastSessions()
    }

    /// The move back of `id` given up on after `wait`, unless its return
    /// has begun by then: then it has handBackReceiveWait more.
    private func handBackTimeout(_ id: String, after wait: Duration, receiving: Bool = false) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, let pending = self.handingBack[id] else { return }
            if pending.receiving, !receiving {
                self.handingBack[id]?.timeout = self.handBackTimeout(id, after: self.handBackReceiveWait, receiving: true)
                return
            }
            let waited = Self.spoken(receiving ? self.handBackReceiveWait : self.handBackWait)
            self.finishHandBack(id, returned: nil, notReturned: receiving ? "its conversation didn't all come within \(waited)"
                                                                         : "its runner's agent didn't return it within \(waited)")
        }
    }

    /// A runner's agent's ReturnConversation begun (its token checked):
    /// where its files go, if its session is moving back and waits for that
    /// agent's conversation. Nil, and nothing is written, otherwise.
    package func handBackArriving(_ session: String, agent: String) -> HandBackTarget? {
        guard let record = self.session(session), let pending = handingBack[record.info.id],
              !pending.agent.isEmpty, pending.agent.lowercased() == agent.lowercased(), !pending.receiving else { return nil }
        handingBack[record.info.id]?.receiving = true
        let cwd = ((pending.cwd.isEmpty ? record.info.cwd : pending.cwd) as NSString).expandingTildeInPath
        let folder = ClaudeSessionFiles.configDirectory()
        return HandBackTarget(session: record.info.id, agent: agent, cwd: cwd, claudeFolder: folder,
                              key: ClaudeSessionFiles.projectDirectoryName(for: cwd), limits: handBackLimits, free: freeBytes(folder))
    }

    /// A returned conversation, whole and staged, put in place, and its
    /// session back here on it: only while its move back still waits for
    /// it. Refused (its staging removed, nothing written), the session
    /// comes back without it.
    package func placeReturned(_ staged: ReturnedConversationIntake.Staged) -> Result<ReturnedConversationIntake.Staged.Placement, ReturnedConversationIntake.Refusal> {
        let target = staged.target
        guard let pending = handingBack[target.session], pending.receiving, pending.agent.lowercased() == target.agent.lowercased() else {
            staged.discard()
            return .failure(.init(.ended, "The session's move back ended before its conversation came."))
        }
        do {
            let placement = try staged.place(stamp: Self.backupStamp(Date()))
            Self.log("the conversation of \(target.session) returned by \(target.agent): \(placement.placed.count) placed, "
                + "\(placement.replaced.count) in place of shorter ones (set aside), \(placement.kept.count) kept as they were here, "
                + "for \(target.cwd) (\(target.key))")
            finishHandBack(target.session, returned: placement.conversation,
                           notReturned: staged.sessionID.isEmpty ? "its runner's agent had no conversation to return"
                                                                 : "its conversation, \(staged.sessionID), wasn't among what came")
            return .success(placement)
        } catch {
            let refusal = (error as? ReturnedConversationIntake.Refusal) ?? .init(.unwritable, "\(error)")
            finishHandBack(target.session, returned: nil, notReturned: "it couldn't be put here: \(refusal.why)")
            return .failure(refusal)
        }
    }

    /// A return refused or broken off part way (its staging removed): the
    /// session back here without it.
    package func handBackFailed(_ session: String, agent: String, why: String) {
        guard let record = self.session(session), let pending = handingBack[record.info.id],
              pending.agent.lowercased() == agent.lowercased() else { return }
        finishHandBack(record.info.id, returned: nil, notReturned: why)
    }

    /// Waits for the move back of `id` to end, if one is under way.
    package func handBackEnded(_ id: String) async {
        guard let key = session(id)?.info.id, handingBack[key] != nil else { return }
        await withCheckedContinuation { continuation in handingBack[key]?.waiters.append(continuation) }
    }

    /// Whether the session `id` is moving back, waiting for its conversation.
    package func isHandingBack(_ id: String) -> Bool {
        session(id).map { handingBack[$0.info.id] != nil } ?? false
    }

    /// The move back of `id` ended: on the conversation `returned`, or,
    /// with none, on the one it had before it moved, saying why its turns
    /// on the runner didn't come (`notReturned`).
    private func finishHandBack(_ id: String, returned: String?, notReturned: String) {
        guard let pending = handingBack.removeValue(forKey: id) else { return }
        pending.timeout?.cancel()
        defer { for waiter in pending.waiters { waiter.resume() } }
        guard let record = session(id), record.driven else { return }
        if let returned {
            bringBack(record, resume: returned, cwd: pending.cwd, why: pending.why, loud: pending.loud, handedBack: true)
        } else {
            Self.log("\(record.info.title) (\(id)): its turns on the runner weren't returned: \(notReturned)")
            bringBack(record, resume: pending.resume, cwd: pending.cwd, why: pending.why, loud: pending.loud, notReturned: notReturned)
        }
    }

    /// "2 minutes", "90 seconds", "150 ms".
    static func spoken(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        if seconds >= 60, seconds % 60 == 0 { return "\(seconds / 60) minutes" }
        if seconds >= 1 { return "\(seconds) seconds" }
        return "\(Int(duration.components.attoseconds / 1_000_000_000_000_000)) ms"
    }

    /// The conversation a moved session carries on here when none is
    /// given: its runner's (move.conversation) when this computer has it
    /// (a native runner here shares Claude's folder), else the one it had
    /// before it moved (move.resume). "" when its move isn't known.
    func knownConversation(of record: SessionRecord) -> String {
        guard let move = record.move ?? jobs?.kept(session: record.info.id) else { return "" }
        // A session begun in the Sessions container moved with nothing: its
        // conversation there is the one it has.
        if move.resume.isEmpty { return move.conversation }
        if !move.conversation.isEmpty, move.conversation != move.resume,
           !SessionCatalog.conversationFiles(agent: .claude, id: move.conversation, cwd: move.cwd).isEmpty {
            return move.conversation
        }
        return move.resume
    }
}
