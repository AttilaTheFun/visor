// The sessions' store: one row a session, in the server's database
// (server.sqlite in its data folder; swift_sql, as the message cache). Each
// row is the session as StoredSession has it, as JSON, beside the few
// things of it a query or an order wants as columns of their own: its
// place in the server's list, its title, whether it's archived, when it
// was pinned and when its latest message came. A write is of the rows that
// changed, in one transaction; the file is in WAL mode, so a crash in the
// middle of one leaves the one before. Before 0.73 the store was
// sessions.json, written whole on every change (VisorServer+SessionImport
// reads it in, once).
//
// Unlike the message cache, nothing here is disposable: the schema only
// ever grows, a step at a time (`migrations`, PRAGMA user_version), and a
// file from a later build, at a version this one doesn't know, isn't
// opened, rather than written by a build that can't read it all.

import Foundation
import SwiftSQL

final class SessionStore: Sendable {
    /// One session's row.
    struct Row: Equatable, Sendable {
        var id: String
        /// Its place in the server's list, from 0.
        var position: Int
        var title: String
        var archived: Bool
        /// When it was pinned (SessionInfo's `pinnedAt`), nil when it isn't.
        var pinnedAt: Double?
        /// When its latest message came (SessionInfo's `updated`).
        var updated: Double?
        /// The session, as StoredSession encodes it (`encoded`).
        var stored: String
    }

    /// Why a store isn't opened.
    struct Refusal: Error, CustomStringConvertible {
        var description: String
    }

    /// The file's path, or ":memory:".
    let path: String
    private let db: Database

    /// Each step from the version before it to its own (the first makes
    /// version 1). Only ever added to: a file a build made reads on in every
    /// build after it.
    static let migrations: [String] = [
        // 1 (0.73): the sessions, and what the store notes of itself (its
        // import from sessions.json).
        """
        CREATE TABLE "sessions" ("id" TEXT PRIMARY KEY NOT NULL, "position" INTEGER NOT NULL, "title" TEXT NOT NULL,
            "archived" INTEGER NOT NULL, "pinned_at" REAL, "updated" REAL, "stored" TEXT NOT NULL);
        CREATE INDEX "index_sessions_on_position" ON "sessions" ("position");
        CREATE TABLE "notes" ("key" TEXT PRIMARY KEY NOT NULL, "value" TEXT NOT NULL);
        """,
    ]

    static var schemaVersion: Int { migrations.count }

    /// The store at a path, made if need be and brought up to this build's
    /// schema; ":memory:" for one in memory. Throws when it can't be opened
    /// or read, and for a file from a later build.
    init(path: String) throws {
        self.path = path
        db = path == ":memory:" ? try Database.inMemory() : try Database(path: path)
        let version = try db.query("PRAGMA user_version") { $0.int(0) }.first ?? 0
        guard version <= Self.schemaVersion else {
            throw Refusal(description: "\((path as NSString).lastPathComponent) is a later Visor's (its schema is \(version), this build's \(Self.schemaVersion))")
        }
        if path != ":memory:" { try db.execute("PRAGMA journal_mode=WAL") }
        for step in version..<Self.schemaVersion {
            try db.transaction(.immediate) { connection in
                try connection.execute(Self.migrations[step])
                try connection.execute("PRAGMA user_version = \(step + 1)")
            }
        }
    }

    // MARK: Reading

    /// Every row, in the list's order.
    func rows() throws -> [Row] {
        try db.query("SELECT id, position, title, archived, pinned_at, updated, stored FROM sessions ORDER BY position, rowid") { row in
            Row(id: row.text(0) ?? "", position: row.int(1), title: row.text(2) ?? "", archived: row.bool(3),
                pinnedAt: row.isNull(4) ? nil : row.double(4), updated: row.isNull(5) ? nil : row.double(5), stored: row.text(6) ?? "")
        }
    }

    func count() throws -> Int {
        try db.query("SELECT COUNT(*) FROM sessions") { $0.int(0) }.first ?? 0
    }

    /// What the store noted under `key`, if anything.
    func note(_ key: String) throws -> String? {
        try db.query("SELECT value FROM notes WHERE key = ?", key) { $0.text(0) }.first ?? nil
    }

    // MARK: Writing

    /// One write, in one transaction: the rows `put` (inserted, or in
    /// place of the row of the same id), the rows `placed` moved to their
    /// new places alone, the rows of `removed` deleted.
    func write(put: [Row], placed: [(id: String, position: Int)] = [], removed: [String] = []) throws {
        try db.transaction(.immediate) { connection in
            try Self.insert(put, into: connection)
            try connection.prepare("UPDATE sessions SET position = ? WHERE id = ?") { statement in
                for place in placed {
                    try statement.bind(place.position, place.id)
                    try statement.run()
                }
            }
            try connection.prepare("DELETE FROM sessions WHERE id = ?") { statement in
                for id in removed {
                    try statement.bind(id)
                    try statement.run()
                }
            }
        }
    }

    /// Every row replaced by `rows`, and `notes` noted, in one transaction:
    /// none of it unless all of it, and the count read back is the count
    /// given (an import's).
    func replaceAll(with rows: [Row], notes: [String: String]) throws {
        try db.transaction(.immediate) { connection in
            try connection.execute("DELETE FROM sessions")
            try Self.insert(rows, into: connection)
            let written = try connection.query("SELECT COUNT(*) FROM sessions") { $0.int(0) }.first ?? 0
            let distinct = Set(rows.map(\.id)).count
            guard written == distinct else {
                throw Refusal(description: "\(distinct) sessions written, \(written) read back")
            }
            try connection.prepare("INSERT OR REPLACE INTO notes (key, value) VALUES (?, ?)") { statement in
                for (key, value) in notes.sorted(by: { $0.key < $1.key }) {
                    try statement.bind(key, value)
                    try statement.run()
                }
            }
        }
    }

    private static func insert(_ rows: [Row], into connection: Connection) throws {
        guard !rows.isEmpty else { return }
        try connection.prepare("""
            INSERT OR REPLACE INTO sessions (id, position, title, archived, pinned_at, updated, stored) VALUES (?, ?, ?, ?, ?, ?, ?)
            """) { statement in
            for row in rows {
                try statement.bind(row.id, row.position, row.title, row.archived, row.pinnedAt, row.updated, row.stored)
                try statement.run()
            }
        }
    }
}

extension SessionStore.Row {
    /// A session's row at a place in the list. Its pin is read from its
    /// info as the protocol has it, so it's the column whether or not this
    /// build's SessionInfo has a `pinnedAt` of its own (#560).
    init(_ session: StoredSession, position: Int) throws {
        self.init(session, encoded: try Self.encoded(session), position: position)
    }

    init(_ session: StoredSession, encoded: String, position: Int) {
        self.init(id: session.info.id, position: position, title: session.info.title, archived: session.info.archived,
                  pinnedAt: session.info.json["pinnedAt"].double, updated: session.info.updated, stored: encoded)
    }

    /// A session as its row keeps it: JSON, its keys sorted, so the same
    /// session is always the same text (and a save can tell it hasn't
    /// changed).
    static func encoded(_ session: StoredSession) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(session), as: UTF8.self)
    }
}
