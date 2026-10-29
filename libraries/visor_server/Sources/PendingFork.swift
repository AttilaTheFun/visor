/// A fork or branch whose agent has not made its own copy of the
/// conversation yet: its next agent starts from `from`, the parent's own
/// session id (up to `at`, a message of it, for a branch), as a copy with
/// an id of its own. Until the copy says its id, the session shows the
/// parent's conversation and follows no file: the parent's file is the
/// parent's.
struct PendingFork: Codable, Hashable, Sendable {
    var from: String
    var at: String?
}
