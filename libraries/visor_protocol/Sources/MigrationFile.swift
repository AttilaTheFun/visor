/// One file a move carries: read where it is a piece at a time, and written
/// where it goes.
public struct MigrationFile: Codable, Equatable, Sendable {
    public var id: String
    /// Where it goes under the agent's own folder (~/.claude, ~/.codex) on
    /// the server the session moves to; `{project}` stands for the folder
    /// the agent keeps the session's project under there. Empty for a
    /// project's copy, which goes where its step says.
    public var place: String
    public var size: Int
    /// A folder packed as one file (a gzipped tar), unpacked where it goes.
    public var packed: Bool

    public init(id: String, place: String, size: Int, packed: Bool) {
        self.id = id
        self.place = place
        self.size = size
        self.packed = packed
    }
}
