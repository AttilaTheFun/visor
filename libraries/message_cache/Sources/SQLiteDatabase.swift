// SQLite through its C API (CSQLite): a connection, and the few things the
// cache asks of one — run some SQL, prepare a statement, the file's own
// version number. The same on every host: the system's SQLite on Apple's
// systems, SQLite's amalgamation elsewhere (`//:sqlite`).

#if MESSAGE_CACHE_SQLITE
import CSQLite

final class SQLiteDatabase {
    let handle: OpaquePointer

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// The file at a path, created if need be; ":memory:" for none.
    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(handle)
            throw Failure(description: message)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit { sqlite3_close_v2(handle) }

    /// Runs statements that answer nothing (`;`-separated).
    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "failed: \(sql)"
            sqlite3_free(error)
            throw Failure(description: message)
        }
    }

    /// Runs one statement with these values for its `?`s.
    func run(_ sql: String, _ values: SQLiteValue...) throws {
        let statement = try prepare(sql)
        try statement.bind(values)
        _ = try statement.step()
    }

    func prepare(_ sql: String) throws -> SQLiteStatement { try SQLiteStatement(database: self, sql: sql) }

    /// The file's own version number (PRAGMA user_version).
    var userVersion: Int32 {
        get {
            guard let statement = try? prepare("PRAGMA user_version"), (try? statement.step()) == true else { return 0 }
            return Int32(statement.int(0))
        }
        set { try? execute("PRAGMA user_version = \(newValue)") }
    }

    /// Runs `body` as one transaction: committed if it returns, rolled back
    /// if it throws.
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var lastError: String { String(cString: sqlite3_errmsg(handle)) }
}
#endif
