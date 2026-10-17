// The cache in SQLite (swift_sqlite): rows by place, an index of their
// words, the tree of their source lines. On every host: the file a cache
// opened with `MessageCache.open(named:)` keeps. The tables are the ones
// SQLite.swift made before (schema 7), so a cache kept by an earlier build
// reads on.

import SwiftSQLite
import VisorProtocol

public final class SQLiteStorage: MessageStorage {
    private let db: Database

    /// The file at a path, created if need be; ":memory:" for none.
    public init(path: String) throws {
        db = path == ":memory:" ? try Database.inMemory() : try Database(path: path)
        if path != ":memory:" { try? db.execute("PRAGMA journal_mode=WAL") }
        let version = (try? db.query("PRAGMA user_version") { $0.int(0) })?.first ?? 0
        if version != MessageCache.schemaVersion {
            try db.execute("""
                DROP TABLE IF EXISTS sources; DROP TABLE IF EXISTS syncs; DROP TABLE IF EXISTS nodes;
                DROP TABLE IF EXISTS messages; DROP TABLE IF EXISTS messages_fts;
                PRAGMA user_version = \(MessageCache.schemaVersion);
                """)
        }
        try db.execute("""
            CREATE TABLE IF NOT EXISTS "sources" ("session" TEXT PRIMARY KEY NOT NULL, "path" TEXT NOT NULL,
                "identity" TEXT NOT NULL, "bytes" INTEGER NOT NULL, "next_seq" INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS "syncs" ("session" TEXT PRIMARY KEY NOT NULL, "revision" INTEGER NOT NULL,
                "generation" INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS "nodes" ("session" TEXT NOT NULL, "seq" INTEGER NOT NULL, "key" TEXT, "parent" TEXT,
                "kind" TEXT NOT NULL, "prompt" INTEGER NOT NULL, PRIMARY KEY ("session", "seq"));
            CREATE TABLE IF NOT EXISTS "messages" ("session" TEXT NOT NULL, "seq" INTEGER NOT NULL, "id" TEXT NOT NULL,
                "role" TEXT NOT NULL, "text" TEXT NOT NULL, "source_key" TEXT, "json" TEXT NOT NULL, PRIMARY KEY ("session", "id"));
            CREATE INDEX IF NOT EXISTS "index_messages_on_session_seq" ON "messages" ("session", "seq");
            CREATE INDEX IF NOT EXISTS "index_messages_on_session_source_key" ON "messages" ("session", "source_key");
            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(session UNINDEXED, id UNINDEXED, role UNINDEXED, text,
                tokenize='unicode61');
            """)
    }

    public func transaction(_ body: () throws -> Void) throws { try db.transaction { _ in try body() } }

    public func sourceState(_ s: String) -> SourceState? {
        first("SELECT path, identity, bytes, next_seq FROM sources WHERE session = ?", [s]) { row in
            SourceState(path: row.text(0) ?? "", identity: row.text(1) ?? "", bytes: UInt64(row.int(2)), nextSeq: row.int(3))
        }
    }

    public func setSourceState(_ state: SourceState, _ s: String) throws {
        try db.run("INSERT OR REPLACE INTO sources (session, path, identity, bytes, next_seq) VALUES (?, ?, ?, ?, ?)",
                   s, state.path, state.identity, Int(state.bytes), state.nextSeq)
    }

    public func syncState(_ s: String) -> SyncState? {
        first("SELECT revision, generation FROM syncs WHERE session = ?", [s]) { SyncState(revision: $0.int(0), generation: $0.int(1)) }
    }

    public func setSyncState(_ state: SyncState, _ s: String) throws {
        try db.run("INSERT OR REPLACE INTO syncs (session, revision, generation) VALUES (?, ?, ?)", s, state.revision, state.generation)
    }

    public func deleteSession(_ s: String) throws {
        try db.run("DELETE FROM sources WHERE session = ?", s)
        try db.run("DELETE FROM syncs WHERE session = ?", s)
        try db.run("DELETE FROM nodes WHERE session = ?", s)
        try deleteMessages(s)
    }

    public func insertNodes(_ s: String, _ new: [SourceNode]) throws {
        try db.prepare("INSERT OR REPLACE INTO nodes (session, seq, key, parent, kind, prompt) VALUES (?, ?, ?, ?, ?, ?)") { statement in
            for node in new {
                try statement.bind(s, node.seq, node.key, node.parentKey, node.kind, node.isPrompt ? 1 : 0)
                try statement.run()
            }
        }
    }

    public func nodes(_ s: String) -> [SourceNode] {
        all("SELECT seq, key, parent, kind, prompt FROM nodes WHERE session = ? ORDER BY seq", [s]) { row in
            SourceNode(seq: row.int(0), key: row.text(1), parentKey: row.text(2), kind: row.text(3) ?? "", isPrompt: row.int(4) != 0)
        }
    }

    public func upsertMessage(_ s: String, _ message: TranscriptEntry, seq position: Int, sourceKey source: String?) throws {
        let kept = seq(s, of: message.id)
        try write(s, message, seq: kept ?? position, sourceKey: source)
        try db.run("DELETE FROM messages_fts WHERE session = ? AND id = ?", s, message.id)
        try index(s, message)
    }

    public func insertMessage(_ s: String, _ message: TranscriptEntry, seq position: Int) throws {
        try write(s, message, seq: position, sourceKey: nil)
        try index(s, message)
    }

    private func write(_ s: String, _ message: TranscriptEntry, seq position: Int, sourceKey source: String?) throws {
        try db.run("INSERT OR REPLACE INTO messages (session, seq, id, role, text, source_key, json) VALUES (?, ?, ?, ?, ?, ?, ?)",
                   s, position, message.id, message.role.rawValue, message.text, source, message.json.encoded())
    }

    private func index(_ s: String, _ message: TranscriptEntry) throws {
        guard !message.text.isEmpty else { return }
        try db.run("INSERT INTO messages_fts (session, id, role, text) VALUES (?, ?, ?, ?)", s, message.id, message.role.rawValue, message.text)
    }

    public func deleteMessages(_ s: String, sourceKeys: Set<String>) throws {
        let keys = Array(sourceKeys)
        for start in stride(from: 0, to: keys.count, by: 500) {
            let chunk = Array(keys[start..<min(start + 500, keys.count)])
            let marks = chunk.map { _ in "?" }.joined(separator: ", ")
            let values: [any SQLiteBindable] = [s] + chunk
            let ids = all("SELECT id FROM messages WHERE session = ? AND source_key IN (\(marks))", values) { $0.text(0) ?? "" }
            for rowID in ids { try db.run("DELETE FROM messages_fts WHERE session = ? AND id = ?", s, rowID) }
            try db.run("DELETE FROM messages WHERE session = ? AND source_key IN (\(marks))", arguments: values)
        }
    }

    public func deleteMessages(_ s: String) throws {
        try db.run("DELETE FROM messages WHERE session = ?", s)
        try db.run("DELETE FROM messages_fts WHERE session = ?", s)
    }

    public func deleteMessages(_ s: String, ids: [String]) throws {
        for id in ids {
            try db.run("DELETE FROM messages WHERE session = ? AND id = ?", s, id)
            try db.run("DELETE FROM messages_fts WHERE session = ? AND id = ?", s, id)
        }
    }

    public func deleteMessages(_ s: String, fromSeq position: Int) throws {
        try db.run("DELETE FROM messages_fts WHERE session = ? AND id IN (SELECT id FROM messages WHERE session = ? AND seq >= ?)",
                   s, s, position)
        try db.run("DELETE FROM messages WHERE session = ? AND seq >= ?", s, position)
    }

    public func messages(_ s: String, limit: Int, before: Int?) -> (messages: [TranscriptEntry], more: Bool) {
        let page: [String] = if let before {
            all("SELECT json FROM messages WHERE session = ? AND seq < ? ORDER BY seq DESC LIMIT ?", [s, before, limit + 1]) { $0.text(0) ?? "" }
        } else {
            all("SELECT json FROM messages WHERE session = ? ORDER BY seq DESC LIMIT ?", [s, limit + 1]) { $0.text(0) ?? "" }
        }
        let entries = page.prefix(limit).reversed().compactMap { parseJSON($0).flatMap(TranscriptEntry.init(json:)) }
        return (entries, page.count > limit)
    }

    public func seq(_ s: String, of messageID: String) -> Int? {
        first("SELECT seq FROM messages WHERE session = ? AND id = ?", [s, messageID]) { $0.int(0) }
    }

    public func seqRange(_ s: String) -> ClosedRange<Int>? {
        first("SELECT MIN(seq), MAX(seq) FROM messages WHERE session = ?", [s]) { row -> ClosedRange<Int>? in
            row.isNull(0) || row.isNull(1) ? nil : row.int(0)...row.int(1)
        } ?? nil
    }

    public func count(_ s: String) -> Int {
        first("SELECT COUNT(*) FROM messages WHERE session = ?", [s]) { $0.int(0) } ?? 0
    }

    public func lastMessage(_ s: String, idPrefixes: [String], userTexts: [String]) -> TranscriptEntry? {
        var clauses: [String] = []
        var values: [any SQLiteBindable] = [s]
        for prefix in idPrefixes {
            clauses.append("id LIKE ?")
            values.append(prefix + "%")
        }
        for words in userTexts {
            clauses.append("(role = 'user' AND text LIKE ?)")
            values.append(words + "%")
        }
        guard !clauses.isEmpty else { return nil }
        let sql = "SELECT json FROM messages WHERE session = ? AND (" + clauses.joined(separator: " OR ") + ") ORDER BY seq DESC LIMIT 1"
        return first(sql, values) { $0.text(0) }.flatMap { $0 }.flatMap { parseJSON($0).flatMap(TranscriptEntry.init(json:)) }
    }

    public func search(_ terms: [String], limit: Int) -> [MessageHit] {
        let match = terms.map { "\"" + $0.replacing("\"", with: "\"\"") + "\"" }.joined(separator: " ")
        return all("SELECT session, id, role, snippet(messages_fts, 3, '', '', '…', 16) FROM messages_fts WHERE messages_fts MATCH ? ORDER BY rank LIMIT ?",
                   [match, limit]) { row in
            MessageHit(session: row.text(0) ?? "", messageID: row.text(1) ?? "",
                       role: TranscriptEntry.Role(rawValue: row.text(2) ?? "") ?? .assistant, snippet: row.text(3) ?? "")
        }
    }

    // MARK: Reading

    private func all<T>(_ sql: String, _ values: [any SQLiteBindable], _ read: (Row) -> T) -> [T] {
        (try? db.query(sql, arguments: values, row: read)) ?? []
    }

    private func first<T>(_ sql: String, _ values: [any SQLiteBindable], _ read: (Row) -> T) -> T? {
        all(sql, values, read).first
    }
}
