// The cache in SQLite, through SQLite.swift: rows by place, an index of
// their words, the tree of their source lines. Where the build has it —
// every Apple host; the browser keeps its cache in memory.

#if MESSAGE_CACHE_SQLITE
import Foundation
import SQLite
import VisorProtocol

public final class SQLiteStorage: MessageStorage, @unchecked Sendable {
    private typealias E<T> = SQLite.Expression<T>
    private let db: Connection
    private let sources = Table("sources")
    private let syncs = Table("syncs")
    private let nodes = Table("nodes")
    private let messages = Table("messages")
    private let session = E<String>("session")
    private let path = E<String>("path")
    private let identity = E<String>("identity")
    private let bytes = E<Int64>("bytes")
    private let nextSeq = E<Int>("next_seq")
    private let revision = E<Int>("revision")
    private let generation = E<Int>("generation")
    private let seq = E<Int>("seq")
    private let key = E<String?>("key")
    private let parentKey = E<String?>("parent")
    private let kind = E<String>("kind")
    private let prompt = E<Bool>("prompt")
    private let id = E<String>("id")
    private let role = E<String>("role")
    private let text = E<String>("text")
    private let sourceKey = E<String?>("source_key")
    private let json = E<String>("json")

    /// The file at a path, created if need be; ":memory:" for none.
    public convenience init(path: String) throws {
        try self.init(connection: path == ":memory:" ? Connection(.inMemory) : Connection(path))
    }

    private init(connection: Connection) throws {
        db = connection
        db.busyTimeout = 5
        try? db.execute("PRAGMA journal_mode=WAL")
        if db.userVersion != Int32(MessageCache.schemaVersion) {
            try db.execute("DROP TABLE IF EXISTS sources; DROP TABLE IF EXISTS syncs; DROP TABLE IF EXISTS nodes; DROP TABLE IF EXISTS messages; DROP TABLE IF EXISTS messages_fts;")
            db.userVersion = Int32(MessageCache.schemaVersion)
        }
        try db.run(sources.create(ifNotExists: true) { t in
            t.column(session, primaryKey: true); t.column(path); t.column(identity); t.column(bytes); t.column(nextSeq)
        })
        try db.run(syncs.create(ifNotExists: true) { t in
            t.column(session, primaryKey: true); t.column(revision); t.column(generation)
        })
        try db.run(nodes.create(ifNotExists: true) { t in
            t.column(session); t.column(seq); t.column(key); t.column(parentKey); t.column(kind); t.column(prompt)
            t.primaryKey(session, seq)
        })
        try db.run(messages.create(ifNotExists: true) { t in
            t.column(session); t.column(seq); t.column(id); t.column(role); t.column(text); t.column(sourceKey); t.column(json)
            t.primaryKey(session, id)
        })
        try db.run(messages.createIndex(session, seq, ifNotExists: true))
        try db.run(messages.createIndex(session, sourceKey, ifNotExists: true))
        try db.execute("CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(session UNINDEXED, id UNINDEXED, role UNINDEXED, text, tokenize='unicode61')")
    }

    public func transaction(_ body: () throws -> Void) throws { try db.transaction { try body() } }

    public func sourceState(_ s: String) -> SourceState? {
        guard let row = try? db.pluck(sources.filter(session == s)) else { return nil }
        return SourceState(path: row[path], identity: row[identity], bytes: UInt64(row[bytes]), nextSeq: row[nextSeq])
    }

    public func setSourceState(_ state: SourceState, _ s: String) throws {
        try db.run(sources.insert(or: .replace, session <- s, path <- state.path, identity <- state.identity, bytes <- Int64(state.bytes), nextSeq <- state.nextSeq))
    }

    public func syncState(_ s: String) -> SyncState? {
        guard let row = try? db.pluck(syncs.filter(session == s)) else { return nil }
        return SyncState(revision: row[revision], generation: row[generation])
    }

    public func setSyncState(_ state: SyncState, _ s: String) throws {
        try db.run(syncs.insert(or: .replace, session <- s, revision <- state.revision, generation <- state.generation))
    }

    public func deleteSession(_ s: String) throws {
        try db.run(sources.filter(session == s).delete())
        try db.run(syncs.filter(session == s).delete())
        try db.run(nodes.filter(session == s).delete())
        try deleteMessages(s)
    }

    public func insertNodes(_ s: String, _ new: [SourceNode]) throws {
        for node in new {
            try db.run(nodes.insert(or: .replace, session <- s, seq <- node.seq, key <- node.key, parentKey <- node.parentKey, kind <- node.kind, prompt <- node.isPrompt))
        }
    }

    public func nodes(_ s: String) -> [SourceNode] {
        (try? db.prepare(nodes.filter(session == s).order(seq)).map {
            SourceNode(seq: $0[seq], key: $0[key], parentKey: $0[parentKey], kind: $0[kind], isPrompt: $0[prompt])
        }) ?? []
    }

    public func upsertMessage(_ s: String, _ message: TranscriptEntry, seq position: Int, sourceKey source: String?) throws {
        let kept = try? db.pluck(messages.select(seq).filter(session == s && id == message.id))
        try db.run(messages.insert(or: .replace, session <- s, seq <- (kept?[seq] ?? position), id <- message.id, role <- message.role.rawValue,
                                   text <- message.text, sourceKey <- source, json <- message.json.encoded()))
        try db.run("DELETE FROM messages_fts WHERE session = ? AND id = ?", s, message.id)
        if !message.text.isEmpty {
            try db.run("INSERT INTO messages_fts (session, id, role, text) VALUES (?, ?, ?, ?)", s, message.id, message.role.rawValue, message.text)
        }
    }

    public func insertMessage(_ s: String, _ message: TranscriptEntry, seq position: Int) throws {
        try db.run(messages.insert(or: .replace, session <- s, seq <- position, id <- message.id, role <- message.role.rawValue,
                                   text <- message.text, sourceKey <- nil, json <- message.json.encoded()))
        if !message.text.isEmpty {
            try db.run("INSERT INTO messages_fts (session, id, role, text) VALUES (?, ?, ?, ?)", s, message.id, message.role.rawValue, message.text)
        }
    }

    public func deleteMessages(_ s: String, sourceKeys: Set<String>) throws {
        for chunk in stride(from: 0, to: sourceKeys.count, by: 500).map({ Array(Array(sourceKeys)[$0..<Swift.min($0 + 500, sourceKeys.count)]) }) {
            let ids = try db.prepare(messages.select(id).filter(session == s && chunk.contains(sourceKey))).map { $0[id] }
            for rowID in ids { try db.run("DELETE FROM messages_fts WHERE session = ? AND id = ?", s, rowID) }
            try db.run(messages.filter(session == s && chunk.contains(sourceKey)).delete())
        }
    }

    public func deleteMessages(_ s: String) throws {
        try db.run(messages.filter(session == s).delete())
        try db.run("DELETE FROM messages_fts WHERE session = ?", s)
    }

    public func messages(_ s: String, limit: Int, before: Int?) -> (messages: [TranscriptEntry], more: Bool) {
        var query = messages.select(seq, json).filter(session == s)
        if let before { query = query.filter(seq < before) }
        let page = (try? db.prepare(query.order(seq.desc).limit(limit + 1)).map { $0[json] }) ?? []
        let entries = page.prefix(limit).reversed().compactMap { parseJSON($0).flatMap(TranscriptEntry.init(json:)) }
        return (entries, page.count > limit)
    }

    public func seq(_ s: String, of messageID: String) -> Int? {
        (try? db.pluck(messages.select(seq).filter(session == s && id == messageID)))?[seq]
    }

    public func seqRange(_ s: String) -> ClosedRange<Int>? {
        guard let low = try? db.scalar(messages.select(seq.min).filter(session == s)),
              let high = try? db.scalar(messages.select(seq.max).filter(session == s)) else { return nil }
        return low...high
    }

    public func count(_ s: String) -> Int { (try? db.scalar(messages.filter(session == s).count)) ?? 0 }

    public func search(_ terms: [String], limit: Int) -> [MessageHit] {
        let match = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " ")
        let statement = try? db.prepare("SELECT session, id, role, snippet(messages_fts, 3, '', '', '…', 16) FROM messages_fts WHERE messages_fts MATCH ? ORDER BY rank LIMIT ?", match, limit)
        return (statement?.map { row in
            MessageHit(session: row[0] as? String ?? "", messageID: row[1] as? String ?? "",
                       role: TranscriptEntry.Role(rawValue: row[2] as? String ?? "") ?? .assistant, snippet: row[3] as? String ?? "")
        }) ?? []
    }
}

extension MessageCache {
    /// A cache on disk under Application Support, by name; in memory if
    /// that cannot be opened.
    public static func open(named name: String) -> MessageCache {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Visor")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let path = base.appendingPathComponent(name + ".sqlite").path
        if let storage = try? SQLiteStorage(path: path) { return MessageCache(storage: storage) }
        return inMemory()
    }

    /// SQLite in memory: the real storage, without a file (tests).
    public static func sqliteInMemory() throws -> MessageCache { MessageCache(storage: try SQLiteStorage(path: ":memory:")) }
}
#else
extension MessageCache {
    /// No SQLite on this host: the cache lives in memory.
    public static func open(named name: String) -> MessageCache { inMemory() }
}
#endif
