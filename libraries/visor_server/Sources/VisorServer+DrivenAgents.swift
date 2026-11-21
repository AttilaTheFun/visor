// A driven session's agent started, stopped and restarted: on its runner,
// never on this computer. Start Agent and Restart Agent queue a resume job
// for a runner of the same kind, carrying on the agent's own conversation
// in the folder it worked in there; Stop Agent lets its job go, so its
// runner ends it. The session stays driven throughout: only moveBack brings
// it here (visor#424: Stop then Start Agent on a moved session started a
// native agent on the Mac, on a fresh conversation).

import Foundation
import VisorAgent
import VisorProtocol

extension VisorServer {
    /// A resume job queued for the driven session's next agent: a new
    /// agent id (its runner's earlier agent may still be on its way out),
    /// the conversation its last agent had, in the folder it worked in on
    /// the runner, with the session's model and title as they are now.
    /// Starting, then running when its wrapper dials in (takeDriven).
    /// False, with a notice saying why, when no job can be queued; the
    /// session stays driven either way.
    @discardableResult
    func resumeDriven(_ record: SessionRecord, why: String) -> Bool {
        guard record.driven else { return false }
        // In the Sessions container: Visor starts its next agent itself.
        if isInContainer(record) { return resumeInContainer(record, why: why) }
        guard let jobs else {
            return refuseDriven(record, "Its agent runs on a runner, and this server takes no jobs for runners: nothing was started.")
        }
        guard var move = record.move ?? jobs.kept(session: record.info.id) else {
            return refuseDriven(record, "Which conversation its runner's agent carried on isn't known here, so no runner can take it up. "
                + "Move it back to this computer to carry it on here.")
        }
        // The agent before goes, with whatever was held for it: nothing
        // meant for it reaches the next one.
        jobs.stopJobs(of: record.info.id)
        if let drivenProcess { record.replaceProcess(drivenProcess(record.info)) }
        move.agent = UUID().uuidString.lowercased()
        move.session = record.info.id
        move.title = record.info.title
        move.model = record.info.model ?? ""
        move.effort = record.info.effort ?? ""
        move.skipPermissions = record.info.skipPermissions
        if case .failure(let refusal) = jobs.queueResume(move) {
            Self.log("\(why) \(record.info.title) (\(record.info.id)) on a runner: \(refusal.reason)")
            return refuseDriven(record, "No runner could be asked to carry it on: \(refusal.reason)")
        }
        record.move = move
        if record.info.busy {
            broadcast(record.apply(.activity(nil)), session: record)
            handle(.busy(false), from: record)
        }
        setAgentState(record, .starting)
        Self.log("\(why) \(record.info.title) (\(record.info.id)) on a \(move.runsOn.isEmpty ? "any" : move.runsOn) runner as \(move.agent), "
            + "carrying on \(move.resumeOnRunner)\(move.workingDirectory.isEmpty ? "" : " in \(move.workingDirectory)")")
        saveArchiveNow()
        broadcastSessions()
        return true
    }

    /// The driven session's agent stopped and kept stopped (Stop Agent):
    /// its job let go, so its runner ends it, and what is said meanwhile
    /// waits for Start Agent. The session stays driven, its move kept.
    func stopDriven(_ record: SessionRecord) {
        Self.log("stopping the runner's agent of \(record.info.title) (\(record.info.id))")
        setAgentState(record, .stopping)
        record.interrupted = false
        jobs?.stopJobs(of: record.info.id)
        // Told to stop if its wrapper is connected; a stop held for one that
        // isn't goes with this process, not to the next agent's wrapper.
        record.process.stop()
        // In the Sessions container: ended there if it doesn't by itself.
        containerRunner.release(session: record.info.id)
        if let drivenProcess { record.replaceProcess(drivenProcess(record.info)) }
        if record.info.busy {
            broadcast(record.apply(.activity(nil)), session: record)
            handle(.busy(false), from: record)
        }
        setAgentState(record, .stopped)
        saveArchiveNow()
        broadcastSessions()
    }

    /// Why a driven session's agent couldn't be started, said on the
    /// session and in the log: false.
    private func refuseDriven(_ record: SessionRecord, _ words: String) -> Bool {
        Self.log("\(record.info.title) (\(record.info.id)): \(words)")
        broadcast(record.apply(.notice(Self.dated(words))), session: record)
        if record.info.agentState == .starting || record.info.agentState == .stopping { setAgentState(record, .stopped) }
        saveArchive()
        broadcastSessions()
        return false
    }

    /// Whether a wrapper that says it is `agent` carries the driven session
    /// on: its move's agent, or any while the move isn't known (one moved
    /// by an older build). An earlier agent of a restarted or stopped
    /// session, dialling in on its way out, isn't taken for the session.
    package func carriesDriven(_ session: String, agent: String) -> Bool {
        guard let record = self.session(session), record.driven, let move = record.move, !move.agent.isEmpty else { return true }
        return move.agent.lowercased() == agent.lowercased()
    }

    /// How often a session's agent may be restarted for a wrapper that
    /// dialled in with an expired token.
    static let expiredTokenResumeInterval: TimeInterval = 600

    /// A runner's agent that dialled in with an expired token (it was
    /// away longer than its token lasts: JobQueue+Tokens), while no wrapper
    /// of it is connected (DriverService): refused, and its session, if that
    /// agent still carries it on, carried on by a resume job with a fresh
    /// token, as Restart Agent would. Once per session in
    /// `expiredTokenResumeInterval`: an old token, however many times it is
    /// shown, restarts its session's agent once at most (the restarted
    /// agent is another, which the old token doesn't name).
    package func resumeAfterExpiredToken(_ session: String, agent: String, now: Date = Date()) {
        guard let record = self.session(session), record.driven, !record.info.archived, carriesDriven(session, agent: agent) else { return }
        if let last = expiredTokenResumes[session], now.timeIntervalSince(last) < Self.expiredTokenResumeInterval {
            Self.log("\(record.info.title) (\(session)): not restarted for an expired token again so soon")
            return
        }
        expiredTokenResumes[session] = now
        resumeDriven(record, why: "restarting, as its wrapper reconnected with an expired token, the agent of")
    }

    /// A moved session's agent started on its runner (agent_protocol's
    /// Started): the harness's own session there, which a later agent of
    /// the session resumes.
    package func drivenAgentStarted(_ session: String, agent: String, conversation: String) {
        guard let record = self.session(session), record.driven, !conversation.isEmpty,
              record.move?.agent.lowercased() == agent.lowercased(), record.move?.conversation != conversation else { return }
        record.move?.conversation = conversation
        saveArchive()
    }

    /// A moved session's job given out again without its runner's agent
    /// coming back (after this server restarted): said on the session, so
    /// a wait for its runner is never silent.
    package func drivenAgentRequeued(_ session: String, why: String) {
        guard let record = self.session(session), record.driven else { return }
        Self.log("\(record.info.title) (\(session)): \(why)")
        broadcast(record.apply(.notice(Self.dated(why))), session: record)
        setAgentState(record, .starting)
        saveArchive()
        broadcastSessions()
    }

    /// A notice with when it was said ("… (16 Nov 2026, 18:20 UTC)"): a
    /// notice stays until it is acknowledged, and one from days before
    /// read as today's (visor#424).
    static func dated(_ words: String, at date: Date = Date()) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "d MMM yyyy, HH:mm"
        return "\(words) (\(format.string(from: date)) UTC)"
    }
}
