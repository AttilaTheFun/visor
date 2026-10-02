import Synchronization
import VisorProtocol

/// What holds the cache: SQLite, or memory. A storage is not asked two
/// things at once: the cache that owns it takes its turn for each.
public protocol MessageStorage: AnyObject {
    func transaction(_ body: () throws -> Void) throws
    func sourceState(_ session: String) -> SourceState?
    func setSourceState(_ state: SourceState, _ session: String) throws
    func syncState(_ session: String) -> SyncState?
    func setSyncState(_ state: SyncState, _ session: String) throws
    func deleteSession(_ session: String) throws
    func insertNodes(_ session: String, _ nodes: [SourceNode]) throws
    func nodes(_ session: String) -> [SourceNode]
    /// Writes a row at `seq`; a row already there by id keeps its place.
    func upsertMessage(_ session: String, _ message: TranscriptEntry, seq: Int, sourceKey: String?) throws
    /// Writes a row known not to be there (the session's rows were just
    /// deleted): nothing is looked up first.
    func insertMessage(_ session: String, _ message: TranscriptEntry, seq: Int) throws
    func deleteMessages(_ session: String, sourceKeys: Set<String>) throws
    func deleteMessages(_ session: String) throws
    func messages(_ session: String, limit: Int, before: Int?) -> (messages: [TranscriptEntry], more: Bool)
    func seq(_ session: String, of messageID: String) -> Int?
    func seqRange(_ session: String) -> ClosedRange<Int>?
    func count(_ session: String) -> Int
    func search(_ terms: [String], limit: Int) -> [MessageHit]
    /// The latest row whose id begins with one of `idPrefixes`, or a
    /// user's row whose words begin with one of `userTexts`.
    func lastMessage(_ session: String, idPrefixes: [String], userTexts: [String]) -> TranscriptEntry?
}

extension MessageStorage {
    /// A storage that cannot look: nothing found, and the rows at hand are
    /// all there is to go by.
    public func lastMessage(_ session: String, idPrefixes: [String], userTexts: [String]) -> TranscriptEntry? { nil }
}
