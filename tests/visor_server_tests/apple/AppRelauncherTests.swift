// An update that does not stay up is undone: the relauncher's watcher,
// run for real on throwaway apps (shell scripts standing in for the
// server), puts the previous build back, says why in the rollback note
// and opens it; one that stays up is left alone.

import Foundation
@testable import VisorServer
@testable import VisorServerApple
import Testing

extension ServerTests {
@Suite @MainActor final class AppRelauncherTests {
    private var root: URL!

    init() async throws {
        TestPlatform.install()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-relauncher-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
    }

    isolated deinit {
        _ = try? run("pkill -f \(AppRelauncher.quoted(root.path))")
        try? FileManager.default.removeItem(at: root)
    }

    /// A stand-in app whose executable runs `body`, marked with `name`.
    private func app(at path: String, name: String, body: String) throws {
        let macOS = (path as NSString).appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(atPath: macOS, withIntermediateDirectories: true)
        let executable = (macOS as NSString).appendingPathComponent("run")
        try "#!/bin/sh\n\(body)\n".write(toFile: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable)
        try name.write(toFile: (path as NSString).appendingPathComponent("name"), atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func run(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test func testANewBuildThatCrashesIsRolledBack() throws {
        let destination = root.appendingPathComponent("Server.app").path
        let backup = root.appendingPathComponent("Previous/Server.app").path
        try app(at: destination, name: "new", body: "exit 1")
        try app(at: backup, name: "old", body: "sleep 30")
        let open = "\(AppRelauncher.quoted(destination + "/Contents/MacOS/run")) >/dev/null 2>&1 &"
        let output = try run(open + "\n" + AppRelauncher.watching(destination: destination, backup: backup, serving: false,
                                                                  newVersion: "0.31 (2)", oldVersion: "0.31 (1)", open: open, seconds: 4))
        #expect(output.contains("rolled back to 0.31 (1): it quit or crashed"), Comment(rawValue: output))
        #expect((try String(contentsOfFile: destination + "/name", encoding: .utf8)) == "old", "the previous build is back")
        #expect(!FileManager.default.fileExists(atPath: backup))
        let note = try String(contentsOf: VisorServer.rollbackNoteURL, encoding: .utf8)
        #expect(note == "Visor Server 0.31 (2) did not stay up after the update (it quit or crashed), so 0.31 (1) was put back.\n")
        #expect(try run("pgrep -f \(AppRelauncher.quoted(destination + "/Contents/MacOS/"))").contains(where: \.isNumber), "and it was opened again")
    }

    @Test func testANewBuildThatStaysUpIsKept() throws {
        let destination = root.appendingPathComponent("Server.app").path
        let backup = root.appendingPathComponent("Previous/Server.app").path
        try app(at: destination, name: "new", body: "sleep 30")
        try app(at: backup, name: "old", body: "sleep 30")
        let open = "\(AppRelauncher.quoted(destination + "/Contents/MacOS/run")) >/dev/null 2>&1 &"
        let output = try run(open + "\n" + AppRelauncher.watching(destination: destination, backup: backup, serving: false,
                                                                  newVersion: "0.31 (2)", oldVersion: "0.31 (1)", open: open, seconds: 4))
        #expect(output.contains("0.31 (2) stayed up"), Comment(rawValue: output))
        #expect((try String(contentsOfFile: destination + "/name", encoding: .utf8)) == "new")
        #expect(!FileManager.default.fileExists(atPath: backup), "the build it replaced is gone once the new one stays up")
        #expect(!(FileManager.default.fileExists(atPath: root.appendingPathComponent("Previous").path)))
        #expect(!FileManager.default.fileExists(atPath: VisorServer.rollbackNoteURL.path))
    }

    @Test func testTheServerSaysItWasRolledBack() throws {
        try "Visor Server 0.31 (2) did not stay up after the update (it quit or crashed), so 0.31 (1) was put back.\n"
            .write(to: VisorServer.rollbackNoteURL, atomically: true, encoding: .utf8)
        VisorServer.secrets = MemorySecrets()
        let server = VisorServer(port: 7985)
        defer { server.stop() }
        #expect(server.updateNotice == "Visor Server 0.31 (2) did not stay up after the update (it quit or crashed), so 0.31 (1) was put back.")
        #expect(!FileManager.default.fileExists(atPath: VisorServer.rollbackNoteURL.path), "said once")
    }
}
}
