// The command-line server's pid file names the process running it. A run
// refused because a server is already running leaves that server's file;
// a server ending takes away its own.

import Foundation
@testable import VisorServerCLI
import XCTest

final class PidFileTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("visor-pid-\(UUID().uuidString).pid")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
    }

    func testAnotherProcesssFileIsLeft() throws {
        try Data("4242 7878\n".utf8).write(to: file)
        ServerCommand.removePidFile(file, ownPID: 1000)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "4242 7878\n")
    }

    func testItsOwnFileGoes() throws {
        try Data("1000 7878\n".utf8).write(to: file)
        ServerCommand.removePidFile(file, ownPID: 1000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        // Already gone: nothing to do.
        ServerCommand.removePidFile(file, ownPID: 1000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
