// A cache of messages: every session's rows in order, where each came
// from, and how far the session has been read or synced. One shape for
// every agent — the rows are the transcript's own — and one for both ends:
// the server fills it from the agents' files, a client from the server.
// Disposable: a cache deleted is rebuilt from the next thing up the chain.

import VisorProtocol

/// How far a source (an agent's own file) has been read into the cache.
public struct SourceState: Sendable, Equatable {
    public var path: String
    /// What tells the file apart from another at the same path (an inode).
    public var identity: String
    public var bytes: UInt64
    public var nextSeq: Int
    public init(path: String, identity: String, bytes: UInt64, nextSeq: Int) {
        self.path = path; self.identity = identity; self.bytes = bytes; self.nextSeq = nextSeq
    }
}

/// How far a session has been synced from the server: the revision held
/// and the generation of the rows.
public struct SyncState: Sendable, Equatable {
    public var revision: Int
    public var generation: Int
    public init(revision: Int, generation: Int) { self.revision = revision; self.generation = generation }
}

/// A line of a source that is a tree of lines (Claude Code's file): its
/// place, what it follows, and whether it begins a turn. Sources without
/// a tree keep none.
public struct SourceNode: Sendable, Equatable {
    public let seq: Int
    public let key: String?
    public let parentKey: String?
    public let kind: String
    public let isPrompt: Bool
    public init(seq: Int, key: String?, parentKey: String?, kind: String, isPrompt: Bool) {
        self.seq = seq; self.key = key; self.parentKey = parentKey; self.kind = kind; self.isPrompt = isPrompt
    }
}

/// A row with its place, and the source line that produced it.
public struct PlacedMessage: Sendable, Equatable {
    public let message: TranscriptEntry
    public let seq: Int
    public let sourceKey: String?
    public init(message: TranscriptEntry, seq: Int, sourceKey: String? = nil) {
        self.message = message; self.seq = seq; self.sourceKey = sourceKey
    }
}

/// A row found by its words.
public struct MessageHit: Sendable, Equatable {
    public let session: String
    public let messageID: String
    public let role: TranscriptEntry.Role
    public let snippet: String
    public init(session: String, messageID: String, role: TranscriptEntry.Role, snippet: String) {
        self.session = session; self.messageID = messageID; self.role = role; self.snippet = snippet
    }
}

/// What holds the cache: SQLite, or memory.
public protocol MessageStorage: AnyObject, Sendable {
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
}

public final class MessageCache: @unchecked Sendable {
    /// Bumped when what is kept, or how, changes: a cache of another
    /// version is dropped and rebuilt.
    public static let schemaVersion = 3

    private let storage: MessageStorage

    public init(storage: MessageStorage) { self.storage = storage }

    /// A cache held in memory alone: what a host without SQLite gets, and
    /// what tests use.
    public static func inMemory() -> MessageCache { MessageCache(storage: MemoryStorage()) }

    // MARK: Sources

    public func sourceState(of session: String) -> SourceState? { storage.sourceState(session) }

    /// Forgets a session and records the source it is read from anew.
    public func resetSource(_ session: String, state: SourceState) throws {
        try storage.transaction {
            try storage.deleteSession(session)
            try storage.setSourceState(state, session)
        }
    }

    /// Writes what one read of a source produced, and where the reading
    /// now stands, together.
    public func ingest(_ session: String, nodes: [SourceNode], messages: [PlacedMessage], state: SourceState) throws {
        try storage.transaction {
            try storage.insertNodes(session, nodes)
            for placed in messages { try storage.upsertMessage(session, placed.message, seq: placed.seq, sourceKey: placed.sourceKey) }
            try storage.setSourceState(state, session)
        }
    }

    public func nodes(in session: String) -> [SourceNode] { storage.nodes(session) }

    /// Drops the rows that lines no longer on the conversation produced.
    public func removeMessages(in session: String, sourceKeys: Set<String>) throws {
        guard !sourceKeys.isEmpty else { return }
        try storage.deleteMessages(session, sourceKeys: sourceKeys)
    }

    // MARK: Messages

    /// The last `limit` rows before a place (or the last of all), in
    /// order, and whether there are rows before those.
    public func messages(in session: String, limit: Int, before seq: Int? = nil) -> (messages: [TranscriptEntry], more: Bool) {
        storage.messages(session, limit: limit, before: seq)
    }

    public func seq(of messageID: String, in session: String) -> Int? { storage.seq(session, of: messageID) }
    public func count(in session: String) -> Int { storage.count(session) }

    /// The rows as a whole, in this order, in place of whatever was kept.
    public func replace(_ session: String, with messages: [TranscriptEntry]) throws {
        try storage.transaction {
            try storage.deleteMessages(session)
            for (index, message) in messages.enumerated() { try storage.insertMessage(session, message, seq: index) }
        }
    }

    /// Rows after the last kept; a row already kept (by id) is updated
    /// where it is.
    public func append(_ session: String, _ messages: [TranscriptEntry]) throws {
        try storage.transaction {
            var next = (storage.seqRange(session)?.upperBound ?? -1) + 1
            for message in messages {
                try storage.upsertMessage(session, message, seq: next, sourceKey: nil)
                next += 1
            }
        }
    }

    /// Rows before the first kept, in order.
    public func prepend(_ session: String, _ messages: [TranscriptEntry]) throws {
        try storage.transaction {
            var first = (storage.seqRange(session)?.lowerBound ?? 0) - messages.count
            for message in messages {
                try storage.upsertMessage(session, message, seq: first, sourceKey: nil)
                first += 1
            }
        }
    }

    public func remove(_ session: String) throws { try storage.deleteSession(session) }

    // MARK: Sync

    public func syncState(of session: String) -> SyncState? { storage.syncState(session) }
    public func setSyncState(_ state: SyncState, for session: String) throws { try storage.setSyncState(state, session) }

    // MARK: Search

    /// Rows whose words match, across every session. Each word of the
    /// query is required; nothing in it is syntax.
    public func search(_ query: String, limit: Int = 50) -> [MessageHit] {
        let terms = query.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        guard !terms.isEmpty else { return [] }
        return storage.search(terms, limit: limit)
    }
}
