// A cache of messages: every session's rows in order, where each came
// from, and how far the session has been read or synced. One shape for
// every agent — the rows are the transcript's own — and one for both ends:
// the server fills it from the agents' files, a client from the server.
// Disposable: a cache deleted is rebuilt from the next thing up the chain.

import Synchronization
import VisorProtocol

/// A cache, used from anywhere: one thing is asked of its storage at a
/// time, and what is written together is written as one.
public final class MessageCache: Sendable {
    /// Bumped when what is kept, or how, changes: a cache of another
    /// version is dropped and rebuilt.
    public static let schemaVersion = 7

    /// Makes the storage `open(named:)` uses, when a host supplies its own
    /// (the browser's IndexedDB); nil, or a nil answer, for the default.
    /// Set before the first cache is opened.
    public static var storageProvider: (@Sendable (_ name: String) -> (any MessageStorage)?)? {
        get { provider.withLock { $0 } }
        set { provider.withLock { $0 = newValue } }
    }
    private static let provider = Mutex<(@Sendable (_ name: String) -> (any MessageStorage)?)?>(nil)

    private let storage: Mutex<any MessageStorage>

    /// A cache over a storage, which is the cache's alone from here on.
    public init(storage: sending any MessageStorage) { self.storage = Mutex(storage) }

    /// A cache held in memory alone: what a host without SQLite gets, and
    /// what tests use.
    public static func inMemory() -> MessageCache { MessageCache(storage: MemoryStorage()) }

    // MARK: Sources

    public func sourceState(of session: String) -> SourceState? { storage.withLock { $0.sourceState(session) } }

    /// Forgets a session and records the source it is read from anew.
    public func resetSource(_ session: String, state: SourceState) throws {
        try storage.withLock { storage in
            try storage.transaction {
                try storage.deleteSession(session)
                try storage.setSourceState(state, session)
            }
        }
    }

    /// Writes what one read of a source produced, and where the reading
    /// now stands, together.
    public func ingest(_ session: String, nodes: [SourceNode], messages: [PlacedMessage], state: SourceState) throws {
        try storage.withLock { storage in
            try storage.transaction {
                try storage.insertNodes(session, nodes)
                for placed in messages { try storage.upsertMessage(session, placed.message, seq: placed.seq, sourceKey: placed.sourceKey) }
                try storage.setSourceState(state, session)
            }
        }
    }

    public func nodes(in session: String) -> [SourceNode] { storage.withLock { $0.nodes(session) } }

    /// Drops the rows that lines no longer on the conversation produced.
    public func removeMessages(in session: String, sourceKeys: Set<String>) throws {
        guard !sourceKeys.isEmpty else { return }
        try storage.withLock { try $0.deleteMessages(session, sourceKeys: sourceKeys) }
    }

    // MARK: Messages

    /// The last `limit` rows before a place (or the last of all), in
    /// order, and whether there are rows before those.
    public func messages(in session: String, limit: Int, before seq: Int? = nil) -> (messages: [TranscriptEntry], more: Bool) {
        storage.withLock { $0.messages(session, limit: limit, before: seq) }
    }

    public func seq(of messageID: String, in session: String) -> Int? { storage.withLock { $0.seq(session, of: messageID) } }
    public func count(in session: String) -> Int { storage.withLock { $0.count(session) } }

    /// The latest row whose id begins with one of `idPrefixes`, or a
    /// user's row whose words begin with one of `userTexts`.
    public func lastMessage(in session: String, idPrefixes: [String], userTexts: [String] = []) -> TranscriptEntry? {
        storage.withLock { $0.lastMessage(session, idPrefixes: idPrefixes, userTexts: userTexts) }
    }

    /// The rows as a whole, in this order, in place of whatever was kept.
    public func replace(_ session: String, with messages: [TranscriptEntry]) throws {
        try storage.withLock { storage in
            try storage.transaction {
                try storage.deleteMessages(session)
                for (index, message) in messages.enumerated() { try storage.insertMessage(session, message, seq: index) }
            }
        }
    }

    /// Rows after the last kept; a row already kept (by id) is updated
    /// where it is.
    public func append(_ session: String, _ messages: [TranscriptEntry]) throws {
        try storage.withLock { storage in
            try storage.transaction {
                var next = (storage.seqRange(session)?.upperBound ?? -1) + 1
                for message in messages {
                    try storage.upsertMessage(session, message, seq: next, sourceKey: nil)
                    next += 1
                }
            }
        }
    }

    /// Rows before the first kept, in order.
    public func prepend(_ session: String, _ messages: [TranscriptEntry]) throws {
        try storage.withLock { storage in
            try storage.transaction {
                var first = (storage.seqRange(session)?.lowerBound ?? 0) - messages.count
                for message in messages {
                    try storage.upsertMessage(session, message, seq: first, sourceKey: nil)
                    first += 1
                }
            }
        }
    }

    public func remove(_ session: String) throws { try storage.withLock { try $0.deleteSession(session) } }

    // MARK: Sync

    public func syncState(of session: String) -> SyncState? { storage.withLock { $0.syncState(session) } }
    public func setSyncState(_ state: SyncState, for session: String) throws { try storage.withLock { try $0.setSyncState(state, session) } }

    // MARK: Search

    /// Rows whose words match, across every session. Each word of the
    /// query is required; nothing in it is syntax.
    public func search(_ query: String, limit: Int = 50) -> [MessageHit] {
        let terms = query.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        guard !terms.isEmpty else { return [] }
        return storage.withLock { $0.search(terms, limit: limit) }
    }
}
