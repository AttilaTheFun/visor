#if MESSAGE_CACHE_SQLITE
import Foundation
import SQLite
import VisorProtocol

extension MessageCache {
    /// A cache on disk under Application Support, by name; in memory if
    /// that cannot be opened.
    public static func open(named name: String) -> MessageCache {
        if let storage = storageProvider?(name) { return MessageCache(storage: storage) }
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
    public static func open(named name: String) -> MessageCache {
        if let storage = storageProvider?(name) { return MessageCache(storage: storage) }
        return inMemory()
    }
}
#endif
