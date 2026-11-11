// A runner's word about a job it claimed (docs/runners.md, "The runner
// protocol"): still on it (renewing its lease), started, done, or failed.

/// A runner's update about a claimed job.
public struct RunnerUpdate: Codable, Hashable, Sendable {
    public enum State: String, Codable, Hashable, Sendable {
        /// Still working on it: the lease is renewed.
        case renew
        /// A start's wrapped agent launched.
        case started
        /// The request carried out (archive, copyOut, startFromCopy, delete).
        case done
        /// It couldn't be done (`problem`). The entry is failed, not requeued.
        case failed
    }

    /// The entry's id.
    public var entry: String
    /// The claim's lease.
    public var lease: String
    public var state: State
    /// Where the session's data lives now, as the runner names it (a folder
    /// on its Sessions volume), for started and done.
    public var dataLocation: String?
    public var problem: String?

    public init(entry: String, lease: String, state: State, dataLocation: String? = nil, problem: String? = nil) {
        self.entry = entry
        self.lease = lease
        self.state = state
        self.dataLocation = dataLocation
        self.problem = problem
    }
}
