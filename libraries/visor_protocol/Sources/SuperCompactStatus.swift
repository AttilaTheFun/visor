/// A Super Compact job as a client follows it (docs/super-compact.md):
/// what `GET /api/sessions/<id>/super-compact` answers, the server's job
/// as it stands. Where it is (the prefilter, the map a chunk at a time,
/// the merge, the final step, or ended), what the check warned of, and,
/// once the person has started the new session from its HANDOFF.md, the
/// session that carries the work on.
public struct SuperCompactStatus: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case prefilter, map, merge, final, done, failed, cancelled

        /// Whether it has ended, one way or another.
        public var ended: Bool { self == .done || self == .failed || self == .cancelled }
    }

    public var id: String
    /// The session it compacts, and its title when the job began.
    public var session: String
    public var title: String
    public var phase: Phase
    /// Where a failed or cancelled job was when it ended.
    public var failedIn: Phase?
    /// The map's chunks done of all of them; the merge's calls likewise.
    public var chunk: Int
    public var chunks: Int
    public var mergeStep: Int
    public var mergeSteps: Int
    /// Why it failed, or the last call that had to be tried again.
    public var error: String?
    /// What the check found missing in HANDOFF.md.
    public var warnings: [String]
    /// HANDOFF.md's path on the server's computer, once written.
    public var handoff: String?
    /// The session started from it (the cut-over), once there is one.
    public var continuedAs: String?
    /// The person discarded the handoff: nothing is to be cut over.
    public var discarded: Bool
    /// When it began, last changed and ended (seconds since 1970).
    public var started: Double
    public var updated: Double
    public var finished: Double?

    public init(id: String, session: String, title: String, phase: Phase, failedIn: Phase? = nil, chunk: Int = 0, chunks: Int = 0,
                mergeStep: Int = 0, mergeSteps: Int = 0, error: String? = nil, warnings: [String] = [], handoff: String? = nil,
                continuedAs: String? = nil, discarded: Bool = false, started: Double, updated: Double? = nil, finished: Double? = nil) {
        self.id = id
        self.session = session
        self.title = title
        self.phase = phase
        self.failedIn = failedIn
        self.chunk = chunk
        self.chunks = chunks
        self.mergeStep = mergeStep
        self.mergeSteps = mergeSteps
        self.error = error
        self.warnings = warnings
        self.handoff = handoff
        self.continuedAs = continuedAs
        self.discarded = discarded
        self.started = started
        self.updated = updated ?? started
        self.finished = finished
    }

    /// Done and waiting for the person's review: neither started from nor
    /// discarded yet.
    public var awaitsReview: Bool { phase == .done && continuedAs == nil && !discarded }

    /// Where it is, in words: "Mapping chunk 12 of 40", "Merging (2 of 5)".
    public var progressWords: String {
        switch phase {
        case .prefilter: "Reading the conversation"
        case .map: chunks > 0 ? "Summarizing chunk \(min(chunk + 1, chunks)) of \(chunks)" : "Summarizing"
        case .merge: mergeSteps > 0 ? "Merging the summaries (\(min(mergeStep + 1, mergeSteps)) of \(mergeSteps))" : "Merging the summaries"
        case .final: "Writing HANDOFF.md"
        case .done: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    /// How far it has come, 0 to 1: the map is most of the work.
    public var fraction: Double {
        switch phase {
        case .prefilter: 0.02
        case .map: 0.05 + 0.8 * (chunks > 0 ? Double(chunk) / Double(chunks) : 0)
        case .merge: 0.85 + 0.1 * (mergeSteps > 0 ? Double(mergeStep) / Double(mergeSteps) : 0)
        case .final: 0.95
        case .done: 1
        case .failed, .cancelled: 0
        }
    }
}
