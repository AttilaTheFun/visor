// The dispatcher across a restart of this server (visor#424): the moves
// the sessions' store keeps are adopted whatever jobs.json kept, a runner's
// renewal, report or wrapper's redial for a moved session's agent takes its
// job back rather than being dropped, a stopped agent's job is let go while
// its session stays moved, and a release that this restart (or an
// unreachable dispatcher) caused isn't counted as a failed start.

import AgentProtocol
import Foundation
import VisorServer

extension JobQueue {
    /// The moves the sessions' store keeps (VisorServer.takeUpDrivenSessions):
    /// each agent the queue doesn't know (jobs.json missing, or behind) is
    /// its session's again, and if `expected` to be running, a claim is held
    /// for it for `redialGrace`, as one taken up from jobs.json is: renewed,
    /// it is its runner's; lapsed, its job goes out again, uncounted. One
    /// jobs.json knows, with no job, ended or was let go: not started again.
    func adopt(_ kept: [AgentJobMove], expected: Set<String>) {
        let expected = Set(expected.map(Self.key))
        var known = 0, held = 0
        for move in kept where !move.agent.isEmpty && !move.resume.isEmpty {
            let id = Self.key(move.agent)
            guard movedSessions[id] == nil else { continue }
            movedSessions[id] = Self.key(move.session)
            moves[id] = (move.resume, move.cwd)
            known += 1
            guard expected.contains(id), claimed[id] == nil, !waiting.contains(where: { $0.agent.uuid == id }) else { continue }
            let expires = Date().addingTimeInterval(Self.redialGrace)
            var job = resumeJob(move, agent: id)
            job.claimExpires = .init(date: expires)
            claimed[id] = (job, "", expires)
            restored.insert(id)
            held += 1
        }
        guard known > 0 || held > 0 else { return }
        save()
        log("dispatcher: \(known) moved sessions known again and \(held) claims held for their runners, from the sessions' own records")
    }

    /// The session's agents' jobs let go, waiting or claimed (Stop Agent,
    /// or before a restart's resume job): a runner's next renewal of one is
    /// refused, and it ends that agent. The agents stay the session's.
    func stopJobs(of session: String) {
        let session = Self.key(session)
        var dropped = 0
        for agent in movedSessions.filter({ $0.value == session }).keys {
            if claimed.removeValue(forKey: agent) != nil { dropped += 1 }
            let before = waiting.count
            waiting.removeAll { $0.agent.uuid == agent }
            dropped += before - waiting.count
            restored.remove(agent)
            returns[agent] = nil
            claimCapabilities[agent] = nil
            // Its job gone, its token is no longer taken (JobQueue+Tokens):
            // its runner's next renewal is told the claim isn't its own, its
            // wrapper can't dial in again, and its reports are let go.
        }
        save()
        if dropped > 0 { log("dispatcher: \(session)'s agent stopped: its job let go") }
    }

    /// What is kept of the session's latest move: its agent, conversation
    /// and folder, and, while its job is held or waiting, its title,
    /// repositories, folder on the runner and kind of runner (a container's
    /// when no job says: every move so far has been).
    func kept(session: String) -> AgentJobMove? {
        let session = Self.key(session)
        let agents = movedSessions.filter { $0.value == session }.keys
        let job = { (agent: String) in self.claimed[agent]?.job ?? self.waiting.first { $0.agent.uuid == agent } }
        guard let agent = agents.first(where: { job($0) != nil }) ?? agents.sorted().first, let move = moves[agent] else { return nil }
        var kept = AgentJobMove(agent: agent, session: session, title: "", resume: move.resume, cwd: move.cwd, runsOn: Self.container)
        if let job = job(agent) {
            kept.title = job.title
            kept.model = job.model
            kept.effort = job.effort
            kept.workingDirectory = job.workingDirectory
            kept.sources = job.sources.map { AgentJobSource(repository: $0.repository, ref: $0.ref, name: $0.name) }
            if let kind = job.labels.first(where: { $0.hasPrefix(Self.runsOn) }) { kept.runsOn = String(kind.dropFirst(Self.runsOn.count)) }
            if !job.resumeSessionID.isEmpty, job.resumeSessionID != move.resume { kept.conversation = job.resumeSessionID }
        }
        return kept
    }

    /// A moved session's wrapper dialled in (AgentDriver.Connect): its
    /// agent is alive, so a job queued again for it meanwhile is its own.
    func heard(_ agent: String) {
        takeBack(Self.key(agent), why: "its wrapper dialled in")
    }

    /// The job of `id`, queued again while its agent was alive (its claim
    /// lapsed while this server restarted, or its runner was slow to come
    /// back), claimed again for it, rather than given to a second agent.
    func takeBack(_ id: String, why: String) {
        guard claimed[id] == nil, let index = waiting.firstIndex(where: { $0.agent.uuid == id }) else { return }
        var job = waiting.remove(at: index)
        let expires = Date().addingTimeInterval(Self.claimLength)
        job.claimExpires = .init(date: expires)
        claimed[id] = (job, "", expires)
        save()
        log("dispatcher: \(id) \(why) while its job waited: it is that agent's again")
    }

    /// Whether a runner's release may be a real failure to start, which
    /// counts toward `attempts`. agent_protocol's Released has only words
    /// (a structured cause is its follow-up), so a release is taken for one
    /// unless its words say the dispatcher or driver was out of reach, or
    /// the runner, its container or this server restarted or went: matched
    /// conservatively, anything else counts.
    nonisolated static func mayBeStartFailure(_ reason: String) -> Bool {
        let words = reason.lowercased()
        return !notStartFailures.contains { words.contains($0) }
    }

    /// What a release says when its agent went for reasons of its
    /// surroundings, not its own.
    nonisolated static let notStartFailures = [
        "unreachable", "couldn't reach", "could not reach", "connection refused", "unavailable",
        "didn't take the job's end", "dispatcher didn't take", "restart", "isn't this runner's",
        "claim wasn't renewed", "primary container is released", "primary vm is released", "its primary was released",
    ]
}
