// What is deprecated (19 Nov 2026) and still works: Visor's dispatcher
// half, which goes once agent jobs run as plain CI jobs on Nimbus's
// runners (they never connect to Visor) and Visor's own container runner
// holds the long-lived sessions; and MultiPass's driver name, MultiPass
// being retired. Each use is said in the server's log the first time in a
// run, never again (docs/runners.md). The wrapper↔driver half (Connect,
// Conversation, the hand-back, the MCP relay, approvals, the agents'
// tokens) and moveToRunner/moveBack aren't.

import Synchronization

package enum Deprecated: String, CaseIterable, Sendable {
    /// A job queued over `POST /api/jobs`.
    case queuedJob
    /// A runner's Claim, from a runner other than Visor's own native one.
    case runnerClaim
    /// A runner token minted or listed (`/api/runners/tokens`).
    case runnerTokens
    /// A driver connection or a job naming `visor.multipass.internal`.
    case multipassName

    /// MultiPass's name for this computer's driver, as containers once
    /// reached it.
    package static let multipassHost = "visor.multipass.internal"

    /// What the REST side says beside its answer (`deprecated`).
    package static let restNote = "Deprecated (19 Nov 2026): agent jobs move to CI (Nimbus's runners), and Visor's own container runner "
        + "holds long-lived sessions. This is removed once agent jobs run on CI."

    /// The line the log says, once.
    package var line: String {
        switch self {
        case .queuedJob:
            "deprecated: agent jobs move to CI: a job was queued over POST /api/jobs, which is removed once agent jobs run on Nimbus CI"
        case .runnerClaim:
            "deprecated: agent jobs move to CI: a runner claimed over AgentDispatcher, which is removed once agent jobs run on Nimbus CI"
        case .runnerTokens:
            "deprecated: agent jobs move to CI: a runner token was minted or listed (/api/runners/tokens), "
                + "which is removed once agent jobs run on Nimbus CI"
        case .multipassName:
            "deprecated: \(Self.multipassHost) (MultiPass is retired): use visor.agent.internal"
        }
    }

    /// Said in the server's log (or `log`, a part's own), the first time
    /// in this run.
    package func noted(_ detail: String = "", log: (@Sendable (String) -> Void)? = nil) {
        Self.notes.note(self, detail, log: log)
    }

    /// This run's.
    static let notes = Notes()

    /// Which of them have been said, and where to say them: the server's
    /// log, or a test's.
    package final class Notes: Sendable {
        private let said = Mutex<Set<Deprecated>>([])
        private let log: @Sendable (String) -> Void

        package init(log: @escaping @Sendable (String) -> Void = { VisorServer.log($0) }) {
            self.log = log
        }

        /// Logs `what` (with `detail`, when there is one) unless it has
        /// been already, to `log` when one is given; whether it was this
        /// time.
        @discardableResult
        package func note(_ what: Deprecated, _ detail: String = "", log given: (@Sendable (String) -> Void)? = nil) -> Bool {
            guard said.withLock({ $0.insert(what).inserted }) else { return false }
            (given ?? log)(what.line + (detail.isEmpty ? "" : " (\(detail))"))
            return true
        }
    }
}
