/// How a session came from another (its `parent`): a fork goes on from
/// the whole conversation, a branch from a point in it.
public enum SessionOrigin: String, Codable, Hashable, Sendable {
    /// A copy of the parent's conversation so far (`/fork`), started on a
    /// prompt of its own while the parent goes on.
    case fork
    /// A copy of the parent's conversation up to a message (`/branch`, or
    /// Branch from Here), idle until the person goes on from it.
    case branch
}
