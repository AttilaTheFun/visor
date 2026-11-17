/// A session's agent left running under its host, as written down: where
/// the host listens, the first line not yet heard from it, what the
/// adapter carries, and which token the agent holds.
struct StoredHost: Codable, Equatable {
    var socket: String
    var line: UInt64
    var carried: [String: String]?
    /// True when the agent was given its session's own token; absent when
    /// it holds the server's shared one, as every agent a build from
    /// before each session had its own (0.59 and earlier) started does.
    var ownToken: Bool?
    /// True when the agent holds a JWT (its token file's, VISOR_TOKEN_FILE);
    /// absent when it holds an older token: the shared one (`ownToken`
    /// absent), or its session's random one of 0.60 and 0.61.
    var jwt: Bool?
}
