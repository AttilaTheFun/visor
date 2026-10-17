import Foundation
import VisorProtocol

extension MessageCache {
    /// A cache in a SQLite file of this name, in `directory` (set by a
    /// host that keeps its files elsewhere: the browser's, a phone's), or
    /// else in the app's Application Support folder; in memory only if no
    /// file can be opened there.
    public static func open(named name: String) -> MessageCache {
        if let storage = storageProvider?(name) { return MessageCache(storage: storage) }
        let base: URL
        if let directory {
            base = URL(fileURLWithPath: directory, isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Visor")
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let path = base.appendingPathComponent(name + ".sqlite").path
        if let storage = try? SQLiteStorage(path: path) { return MessageCache(storage: storage) }
        return inMemory()
    }

    /// SQLite in memory: the real storage, without a file (tests).
    public static func sqliteInMemory() throws -> MessageCache { MessageCache(storage: try SQLiteStorage(path: ":memory:")) }
}
