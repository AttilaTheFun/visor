// Words handed to an agent that went before its log had them — it exited
// as it started (its container gone, say), or was replaced mid-turn — were
// never taken: no later agent has them. They stop showing as delivered at
// once (SessionRecord.agentWent), and once the log has had a few seconds to
// catch up, the session names the ones never written, to be said again,
// rather than show them under every later turn as on their way.

import Foundation

extension VisorServer {
    /// How long the log is given to write what a gone agent was handed.
    static var untakenGrace: Duration = .seconds(10)

    /// After the session's agent went: what it never took is looked for
    /// once the log has caught up, and the session says so.
    func noteAgentWent(_ record: SessionRecord) {
        guard record.agentWent() else { return }
        let grace = Self.untakenGrace
        Task {
            try? await Task.sleep(for: grace)
            guard sessions.contains(where: { $0 === record }) else { return }
            // A command (`/goal`) its log may never write: let go of quietly.
            let untaken = record.dropUntaken(after: grace).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") }
            guard !untaken.isEmpty else { return }
            Self.log("session \(record.info.title): its agent went before it took \(untaken.count) message(s)")
            let quoted = untaken.map { "“" + ($0.count > 60 ? String($0.prefix(60)) + "…" : $0) + "”" }.joined(separator: ", ")
            broadcast(record.apply(.notice("The agent ended before it took \(quoted): say \(untaken.count == 1 ? "it" : "them") again.")),
                      session: record)
        }
    }
}
