// Agents that outlive the server: each runs under a host of its own
// (HostedChild), so a restart or an update of the server leaves it
// working. Going for a restart, the server lets its hosts go and writes
// down where each listens and what it last heard; the next launch connects
// to each again and is sent what it missed. A plain quit still ends them.

import Foundation
import VisorProtocol

extension VisorServer {
    /// Picks up the agent an earlier launch left under `host`. Gone — the
    /// host ended, or the computer restarted — the session is as a restart
    /// left it: an agent that outlived its host is ended, and a turn that
    /// was in flight is carried on.
    func pickUp(_ record: SessionRecord, host: StoredHost, agentPID: Int32?, resume: String?) async {
        defer { record.leftHost = nil }
        if let hosting = ServerPlatform.current.agentHosts, let hostable = record.process as? HostableProcess,
           let child = await HostedChild.attach(socket: host.socket, from: host.line, hosting: hosting) {
            if !record.isBound { bind(record) }
            hostable.adopt(child, carried: host.carried ?? [:])
            child.limit(AgentChildren.memoryLimit)
            Self.log("picked up the agent of \(record.info.title) (\(record.info.id))")
            // Still working on the turn it had when the last launch went:
            // it says when that ends, as ever (unless what it said was
            // more than its host keeps, and the end may be among it).
            if record.interrupted, child.isRunning, !child.missedLines { broadcast(record.apply(.busy(true)), session: record) }
        } else {
            if let agentPID { await Self.endOrphan(pid: agentPID, resume: resume) }
            if record.interrupted, !record.info.archived { pendingResumes.append(record.info.id) }
        }
        release(record)
        if listening { resumePending() }
        broadcastSessions()
    }

    /// Lets every hosted agent go on without this server, which is going
    /// for a restart, and writes down where each is; ends the rest. What a
    /// relaunch does in place of `endAll`.
    func leaveAgents() async {
        // No more is heard from the hosts, so what is written down is
        // where each next launch picks up; a moment for what is already
        // on its way to be taken.
        let leaving = sessions.filter { ($0.process as? HostableProcess)?.hostedChild != nil }
        for record in leaving { (record.process as? HostableProcess)?.hostedChild?.detach() }
        try? await Task.sleep(for: .milliseconds(200))
        for record in sessions where record.info.busy { record.interrupted = true }
        saveArchive()
        for record in sessions { record.stopListening() }
        let ending = sessions.filter { record in !leaving.contains { $0 === record } }
            .map { record in Task { await record.process.end(within: .seconds(4)) } }
        for task in ending { await task.value }
        agentsEnded = true
    }

    /// A new limit for every session's agent and what it runs.
    func setAgentMemoryLimit(_ bytes: UInt64) {
        AgentChildren.memoryLimit = bytes
        for record in sessions { (record.process as? HostableProcess)?.hostedChild?.limit(bytes) }
    }
}
