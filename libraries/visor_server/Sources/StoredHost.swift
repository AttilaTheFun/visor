/// A session's agent left running under its host, as written down: where
/// the host listens, the first line not yet heard from it, and what the
/// adapter carries.
struct StoredHost: Codable, Equatable {
    var socket: String
    var line: UInt64
    var carried: [String: String]?
}
