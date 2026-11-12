// A command-line server's successor is started as a daemon, which nobody
// waits for: a program that could not be started is said at the start,
// where the server relaunching can still stay, rather than lost in a child
// that exits unseen while the old server quits.

import Foundation
import VisorServerPOSIX
import Testing

extension ServerTests {
@Suite final class DetachedStartTests {
    private var log: URL!

    init() {
        log = FileManager.default.temporaryDirectory.appendingPathComponent("visor-detached-\(UUID().uuidString).log")
    }

    deinit {
        try? FileManager.default.removeItem(at: log)
    }

    @Test func testAProgramThatIsNotThereIsAnError() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("visor-server-\(UUID().uuidString) (deleted)").path
        let error = #expect(throws: (any Error).self) { try POSIXDaemon.start(missing, ["run"], log: log.path) }
        #expect((error as? NSError)?.code == Int(ENOENT))
    }

    @Test func testAProgramThatStartsIsItsProcess() throws {
        let pid = try POSIXDaemon.start("/bin/sh", ["-c", "echo started"], log: log.path)
        #expect(pid > 0)
        var status: Int32 = 0
        #expect(waitpid(pid, &status, 0) == pid)
        #expect((try String(contentsOf: log, encoding: .utf8)) == "started\n")
    }
}
}
