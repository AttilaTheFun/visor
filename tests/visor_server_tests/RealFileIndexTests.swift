// Indexes a real session file named by VISOR_REAL_FILE (skipped otherwise):
// how long it takes, and whether every write goes through.
import ClaudeTranscript
import MessageCache
import VisorProtocol
@testable import VisorServer
import XCTest

final class RealFileIndexTests: XCTestCase {
    func testIndexesTheRealFile() async throws {
        guard let path = ProcessInfo.processInfo.environment["VISOR_REAL_FILE"] else { throw XCTSkip("no VISOR_REAL_FILE") }
        let dbPath = FileManager.default.temporaryDirectory.appendingPathComponent("visor-real-\(UUID().uuidString).sqlite").path
        let store = MessageCache(storage: try SQLiteStorage(path: dbPath))
        let started = Date()
        let indexer = SessionIndexer(store: store, sessionID: "R", url: URL(fileURLWithPath: path), window: 600)
        let loaded: SessionIndexer.Loaded = await withCheckedContinuation { c in
            indexer.start(onLoaded: { c.resume(returning: $0) }, onLines: { _ in })
        }
        let elapsed = Date().timeIntervalSince(started)
        print("REAL: \(String(format: "%.1f", elapsed))s, window \(loaded.rows.count), more \(loaded.more), prompts \(loaded.prompts.count), abandoned \(loaded.abandoned.count), rows in store \(store.count(in: "R")), state \(String(describing: store.sourceState(of: "R")))")
        XCTAssertGreaterThan(store.count(in: "R"), 0)
        indexer.stop()
    }
}
