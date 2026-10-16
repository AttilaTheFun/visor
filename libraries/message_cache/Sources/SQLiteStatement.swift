#if MESSAGE_CACHE_SQLITE
import CSQLite

/// A prepared statement: values bound, stepped through its rows, read by
/// column.
final class SQLiteStatement {
    private let handle: OpaquePointer
    private let database: SQLiteDatabase

    init(database: SQLiteDatabase, sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(database.handle, sql, -1, &handle, nil) == SQLITE_OK, let handle else {
            throw SQLiteDatabase.Failure(description: database.lastError + " (" + sql + ")")
        }
        self.handle = handle
        self.database = database
    }

    deinit { sqlite3_finalize(handle) }

    /// SQLite copies a bound string at once.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func bind(_ values: [SQLiteValue]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result = switch value {
            case .int(let number): sqlite3_bind_int64(handle, index, sqlite3_int64(number))
            case .text(let text): sqlite3_bind_text(handle, index, text, -1, Self.transient)
            case .null: sqlite3_bind_null(handle, index)
            }
            guard result == SQLITE_OK else { throw SQLiteDatabase.Failure(description: database.lastError) }
        }
    }

    /// The next row: true while there is one, false at the end.
    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteDatabase.Failure(description: database.lastError)
        }
    }

    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(handle, column)) }

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }

    func text(_ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: bytes)
    }

    /// Every row's value from one reading of each.
    func rows<T>(_ read: (SQLiteStatement) -> T) -> [T] {
        var rows: [T] = []
        while (try? step()) == true { rows.append(read(self)) }
        return rows
    }
}
#endif
