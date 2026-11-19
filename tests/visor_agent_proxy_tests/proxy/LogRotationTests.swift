// agent-proxy's own log, moved aside past its limit (LogRotation): launchd
// opens it once, so the process does it itself, onto the same descriptors.

import VisorAgentProxyHost
import Foundation
import XCTest
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class LogRotationTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("log-rotation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ text: String, to descriptor: Int32) {
        _ = Array(text.utf8).withUnsafeBytes { Foundation.write(descriptor, $0.baseAddress, $0.count) }
    }

    func testALogPastItsLimitIsMovedAsideAndANewOneBegun() throws {
        let path = folder.appendingPathComponent("agent-proxy.log").path
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        let other = dup(descriptor)
        defer { close(descriptor); close(other) }
        write(String(repeating: "a", count: 40), to: descriptor)
        XCTAssertFalse(LogRotation.rotate(path, limit: 50, descriptors: [descriptor, other]), "within its limit")
        write(String(repeating: "b", count: 40), to: descriptor)
        XCTAssertTrue(LogRotation.rotate(path, limit: 50, descriptors: [descriptor, other]))
        XCTAssertEqual(try String(contentsOfFile: path + ".1", encoding: .utf8), String(repeating: "a", count: 40) + String(repeating: "b", count: 40))
        write("after\n", to: descriptor)
        write("both\n", to: other)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "after\nboth\n", "each descriptor that was the log is the new one")
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        // Again past it: the one before replaced.
        write(String(repeating: "c", count: 60), to: descriptor)
        XCTAssertTrue(LogRotation.rotate(path, limit: 50, descriptors: [descriptor]))
        XCTAssertEqual(try String(contentsOfFile: path + ".1", encoding: .utf8), "after\nboth\n" + String(repeating: "c", count: 60))
    }

    /// A descriptor that isn't the file at the path (a terminal, another
    /// file, the path moved by someone else) is left alone.
    func testADescriptorThatIsntTheLogIsLeftAlone() throws {
        let path = folder.appendingPathComponent("agent-proxy.log").path
        let elsewhere = folder.appendingPathComponent("other.log").path
        let descriptor = open(elsewhere, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        defer { close(descriptor) }
        write(String(repeating: "x", count: 100), to: descriptor)
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data(repeating: 0x79, count: 100)))
        XCTAssertFalse(LogRotation.rotate(path, limit: 50, descriptors: [descriptor]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".1"))
        XCTAssertFalse(LogRotation.rotate(folder.appendingPathComponent("none.log").path, limit: 50, descriptors: [descriptor]))
        XCTAssertFalse(LogRotation.rotate(path, limit: 50, descriptors: []))
        XCTAssertEqual(LogRotation.defaultLimit, 8 << 20)
    }
}
