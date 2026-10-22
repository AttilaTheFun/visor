/// A session's agent left running in its container on oss, as written
/// down: its process there, where its output and its errors were read to,
/// and what the adapter carries. The next launch reads on from there.
struct StoredContainerProcess: Codable, Equatable {
    var process: String
    var out: Int
    var err: Int
    var carried: [String: String]?
}
