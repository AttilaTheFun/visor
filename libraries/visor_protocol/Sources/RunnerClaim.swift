// What a runner's poll returns when it claims a job (docs/runners.md, "The
// runner protocol"): the entry, its lease, and for a start the agent's
// one-time token. The runner renews the lease (RunnerUpdate) while it works;
// one that lapses puts the entry back in the queue.

import Foundation

/// A job a runner has claimed from the queue.
public struct RunnerClaim: Codable, Hashable, Sendable {
    public var entry: QueueEntry
    /// The lease's id, which every update about this job carries.
    public var lease: String
    public var expires: Date
    /// For a start: a one-time token for the session's agent, which
    /// MultiPass checks when the agent dials in.
    public var agentToken: String?

    public init(entry: QueueEntry, lease: String, expires: Date, agentToken: String? = nil) {
        self.entry = entry
        self.lease = lease
        self.expires = expires
        self.agentToken = agentToken
    }
}
