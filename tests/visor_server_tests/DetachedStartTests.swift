// A command-line server's successor is started as a daemon, which nobody
// waits for: a program that could not be started is said at the start,
// where the server relaunching can still stay, rather than lost in a child
// that exits unseen while the old server quits.

import Foundation
import VisorServerPOSIX
import XCTest

final class DetachedStartTests: XCTestCase {
    private var log: URL!

    override func setUp() {
        log = FileManager.default.temporaryDirectory.appendingPathComponent("visor-detached-\(UUID().uuidString).log")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: log)
    }

    func testAProgramThatIsNotThereIsAnError() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("visor-server-\(UUID().uuidString) (deleted)").path
        XCTAssertThrowsError(try POSIXDaemon.start(missing, ["run"], log: log.path)) { error in
            XCTAssertEqual((error as NSError).code, Int(ENOENT))
        }
    }

    func testAProgramThatStartsIsItsProcess() throws {
        let pid = try POSIXDaemon.start("/bin/sh", ["-c", "echo started"], log: log.path)
        XCTAssertGreaterThan(pid, 0)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, 0), pid)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "started\n")
    }
}
