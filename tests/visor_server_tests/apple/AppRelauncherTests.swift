// An update that does not stay up is undone, and the server says so once.
// The relauncher's watcher itself (AppRelaunchWatch) is run for real on
// throwaway apps, on Linux: //tests/visor_launch_agent_tests,
// AppRelaunchWatchTests.

import Foundation
@testable import VisorServer
import XCTest

@MainActor
final class AppRelauncherTests: AppleServerTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-relauncher-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheServerSaysItWasRolledBack() throws {
        try "Visor Server 0.31 (2) did not stay up after the update (it quit or crashed), so 0.31 (1) was put back.\n"
            .write(to: VisorServer.rollbackNoteURL, atomically: true, encoding: .utf8)
        VisorServer.secrets = MemorySecrets()
        let server = VisorServer(port: 7985)
        defer { server.stop() }
        XCTAssertEqual(server.updateNotice, "Visor Server 0.31 (2) did not stay up after the update (it quit or crashed), so 0.31 (1) was put back.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: VisorServer.rollbackNoteURL.path), "said once")
    }
}
