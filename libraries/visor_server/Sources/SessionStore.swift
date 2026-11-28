// The sessions' store: one row a session, in the server's database
// (server.sqlite in its data folder; swift_sql, as the message cache). Each
// row is the session as StoredSession has it, as JSON, beside the few
// things of it a query or an order wants as columns of their own: its
// place in the server's list, its title, whether it's archived or pinned,
// and when its latest message came. Its pin is the column's alone: the
// session's JSON never has one (SessionRecord.stored). A write is of the rows that
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
        /// Pinned to the top of its computer's list (SessionInfo's `pinned`).
        var pinned: Bool = false
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
        // imports: sessions.json, and the pins messages.sqlite kept).
        """
        CREATE TABLE "sessions" ("id" TEXT PRIMARY KEY NOT NULL, "position" INTEGER NOT NULL, "title" TEXT NOT NULL,
            "archived" INTEGER NOT NULL, "pinned" INTEGER NOT NULL DEFAULT 0, "updated" REAL, "stored" TEXT NOT NULL);
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
        try db.query("SELECT id, position, title, archived, pinned, updated, stored FROM sessions ORDER BY position, rowid") { row in
            Row(id: row.text(0) ?? "", position: row.int(1), title: row.text(2) ?? "", archived: row.bool(3),
                pinned: row.bool(4), updated: row.isNull(5) ? nil : row.double(5), stored: row.text(6) ?? "")
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
    /// place of the row of the same id), the rows `placed` given their new
    /// places and pins alone, the rows of `removed` deleted.
    func write(put: [Row], placed: [(id: String, position: Int, pinned: Bool)] = [], removed: [String] = []) throws {
        try db.transaction(.immediate) { connection in
            try Self.insert(put, into: connection)
            try connection.prepare("UPDATE sessions SET position = ?, pinned = ? WHERE id = ?") { statement in
                for place in placed {
                    try statement.bind(place.position, place.pinned, place.id)
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

    /// What a merge did: the rows it left as they were (sessions the file
    /// it came from didn't have), the rows it brought up to date, and the
    /// rows it added.
    struct Merged: Equatable, Sendable {
        var kept: Int
        var updated: Int
        var added: Int
    }

    /// `rows` merged in, and `notes` noted, in one transaction: a row of the
    /// same id brought up to date (its title, whether it's archived, when
    /// its latest message came, the session itself; its place and its pin
    /// as they were), one that isn't here added after the rest, in the
    /// order given, and every row not among them left as it is. None of it
    /// unless all of it, and the count read back is the count there should
    /// be (an import's).
    @discardableResult
    func merge(_ rows: [Row], notes: [String: String]) throws -> Merged {
        try db.transaction(.immediate) { connection in
            let here = try connection.query("SELECT id, position FROM sessions") { (id: $0.text(0) ?? "", position: $0.int(1)) }
            let ids = Set(here.map(\.id))
            var next = (here.map(\.position).max() ?? -1) + 1
            var updated = 0
            try connection.prepare("UPDATE sessions SET title = ?, archived = ?, updated = ?, stored = ? WHERE id = ?") { statement in
                for row in rows where ids.contains(row.id) {
                    try statement.bind(row.title, row.archived, row.updated, row.stored, row.id)
                    updated += try statement.run()
                }
            }
            var added: [Row] = []
            for var row in rows where !ids.contains(row.id) && !added.contains(where: { $0.id == row.id }) {
                row.position = next
                next += 1
                added.append(row)
            }
            try Self.insert(added, into: connection)
            let expected = ids.union(rows.map(\.id)).count
            let written = try connection.query("SELECT COUNT(*) FROM sessions") { $0.int(0) }.first ?? 0
            guard written == expected else {
                throw Refusal(description: "\(expected) sessions there should be, \(written) read back")
            }
            try Self.note(notes, in: connection)
            return Merged(kept: ids.subtracting(rows.map(\.id)).count, updated: updated, added: added.count)
        }
    }

    /// The whole store copied to a file of its own at `path` (one file,
    /// what its log holds included: VACUUM INTO), which must not be there.
    func copy(to path: String) throws {
        try db.run("VACUUM INTO ?", path)
    }

    /// These sessions pinned (those of them here and not archived), and
    /// `notes` noted, in one transaction: how many were pinned.
    @discardableResult
    func pin(_ ids: Set<String>, notes: [String: String]) throws -> Int {
        try db.transaction(.immediate) { connection in
            var pinned = 0
            try connection.prepare("UPDATE sessions SET pinned = 1 WHERE id = ? AND archived = 0") { statement in
                for id in ids.sorted() {
                    try statement.bind(id)
                    pinned += try statement.run()
                }
            }
            try Self.note(notes, in: connection)
            return pinned
        }
    }

    private static func note(_ notes: [String: String], in connection: Connection) throws {
        try connection.prepare("INSERT OR REPLACE INTO notes (key, value) VALUES (?, ?)") { statement in
            for (key, value) in notes.sorted(by: { $0.key < $1.key }) {
                try statement.bind(key, value)
                try statement.run()
            }
        }
    }

    private static func insert(_ rows: [Row], into connection: Connection) throws {
        guard !rows.isEmpty else { return }
        try connection.prepare("""
            INSERT OR REPLACE INTO sessions (id, position, title, archived, pinned, updated, stored) VALUES (?, ?, ?, ?, ?, ?, ?)
            """) { statement in
            for row in rows {
                try statement.bind(row.id, row.position, row.title, row.archived, row.pinned, row.updated, row.stored)
                try statement.run()
            }
        }
    }
}

extension SessionStore.Row {
    /// A session's row at a place in the list, pinned or not.
    init(_ session: StoredSession, position: Int, pinned: Bool = false) throws {
        self.init(session, encoded: try Self.encoded(session), position: position, pinned: pinned)
    }

    init(_ session: StoredSession, encoded: String, position: Int, pinned: Bool) {
        self.init(id: session.info.id, position: position, title: session.info.title, archived: session.info.archived,
                  pinned: pinned, updated: session.info.updated, stored: encoded)
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
