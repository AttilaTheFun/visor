/// One session of a backup (SessionBackup): which it is, and what was done
/// with it — backed up, or not and why; restored, put back in part, or left
/// as it was here.
public struct SessionBackupItem: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// What became of it, in words: "Backed up.", "Restored.", "Here
    /// already: left as it is.", or why not.
    public var outcome: String
    /// Whether it is in the backup, to be restored.
    public var kept: Bool

    public init(id: String, title: String, outcome: String, kept: Bool) {
        self.id = id
        self.title = title
        self.outcome = outcome
        self.kept = kept
    }
}
