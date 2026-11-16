/// A session's agent left running under its host, as written down: where
/// the host listens, the first line not yet heard from it, what the
/// adapter carries, and whether the agent holds its session's own token.
struct StoredHost: Codable, Equatable {
    var socket: String
    var line: UInt64
    var carried: [String: String]?
    /// True when the agent was given its session's own token; absent when
    /// it holds the server's shared one, as every agent a build from
    /// before each session had its own (0.59 and earlier) started does.
    var ownToken: Bool?
}
