// The command-line server's pid file names the process running it. A run
// refused because a server is already running leaves that server's file;
// a server ending takes away its own.

import Foundation
@testable import VisorServerCLI
import Testing

extension ServerTests {
@Suite final class PidFileTests {
    private var file: URL!

    init() {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("visor-pid-\(UUID().uuidString).pid")
    }

    deinit {
        try? FileManager.default.removeItem(at: file)
    }

    @Test func testAnotherProcesssFileIsLeft() throws {
        try Data("4242 7878\n".utf8).write(to: file)
        ServerCommand.removePidFile(file, ownPID: 1000)
        #expect((try String(contentsOf: file, encoding: .utf8)) == "4242 7878\n")
    }

    @Test func testItsOwnFileGoes() throws {
        try Data("1000 7878\n".utf8).write(to: file)
        ServerCommand.removePidFile(file, ownPID: 1000)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // Already gone: nothing to do.
        ServerCommand.removePidFile(file, ownPID: 1000)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
}
