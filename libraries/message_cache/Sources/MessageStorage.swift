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
    /// Deletes these rows, by id.
    func deleteMessages(_ session: String, ids: [String]) throws
    /// Deletes the rows at `seq` and after it.
    func deleteMessages(_ session: String, fromSeq seq: Int) throws
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

    /// For a storage a host made before these could be asked of it: the
    /// rows read, and written back without those that go.
    public func deleteMessages(_ session: String, ids: [String]) throws {
        let gone = Set(ids)
        try keepOnly(session) { !gone.contains($0.message.id) }
    }

    public func deleteMessages(_ session: String, fromSeq seq: Int) throws {
        try keepOnly(session) { $0.seq < seq }
    }

    private func keepOnly(_ session: String, _ keep: ((message: TranscriptEntry, seq: Int)) -> Bool) throws {
        let all = messages(session, limit: 1 << 30, before: nil).messages
        let kept = all.map { (message: $0, seq: self.seq(session, of: $0.id) ?? 0) }.filter(keep)
        guard kept.count < all.count else { return }
        try deleteMessages(session)
        for row in kept { try insertMessage(session, row.message, seq: row.seq) }
    }
}
