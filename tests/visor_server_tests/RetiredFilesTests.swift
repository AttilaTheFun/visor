// The files MultiPass and removed parts of Visor left in its data folder
// (RetiredFiles): moved aside into `retired-<date>/` at the server's start,
// never deleted; nothing else of the folder's touched; and a second start
// does nothing.

import Foundation
@testable import VisorServer
import Testing

extension ServerTests {
@Suite final class RetiredFilesTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-retired-files-" + UUID().uuidString)
    private let files = FileManager.default
    /// 19 Nov 2026, 12:00 UTC.
    private let day = Date(timeIntervalSince1970: 1_795_089_600)

    init() throws {
        try files.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, _ text: String = "kept") throws {
        let url = root.appendingPathComponent(name)
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func text(_ path: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func testTheLeftoversAreMovedAsideAndNothingElse() throws {
        for name in ["runner.json", "runner-secrets.json", "runner-secrets.json.lock", "hosts.jsonl", "github-proxy-ca.pem"] {
            try write(name, name)
        }
        try write("containers/home/.netrc", "netrc")
        try write("container-tools/tool", "tool")
        // What Visor reads, and names like the leftovers' that aren't them.
        let kept = ["sessions.json", "settings.json", "jobs.json", "visor_mcp.js", "hosts/hosts.log", "hosts/s1/token",
                    "runner.json.bak", "Runner.json", "containers.txt", "backups/b1/offer.json", "Sessions/x"]
        for name in kept { try write(name, name) }

        var said: [String] = []
        let moved = RetiredFiles.moveAside(in: root, on: day, files: files) { said.append($0) }
        #expect(Set(moved) == Set(RetiredFiles.names))

        let retired = "retired-2026-11-19/"
        for name in ["runner.json", "runner-secrets.json", "runner-secrets.json.lock", "hosts.jsonl", "github-proxy-ca.pem"] {
            #expect(text(name) == nil, "\(name) moved")
            #expect(text(retired + name) == name, "\(name) kept, as it was, in \(retired)")
        }
        #expect(!files.fileExists(atPath: root.appendingPathComponent("containers").path))
        #expect(text(retired + "containers/home/.netrc") == "netrc", "a folder moved whole")
        #expect(text(retired + "container-tools/tool") == "tool")
        for name in kept { #expect(text(name) == name, "\(name) untouched") }
        #expect(said.count == 1 && said[0].contains("retired-2026-11-19") && said[0].contains("hosts.jsonl"), "logged: \(said)")

        // A second start: nothing to move, nothing said, nothing changed.
        let before = try files.subpathsOfDirectory(atPath: root.path).sorted()
        said = []
        #expect(RetiredFiles.moveAside(in: root, on: day.addingTimeInterval(86_400), files: files) { said.append($0) }.isEmpty)
        #expect(said.isEmpty)
        #expect(try files.subpathsOfDirectory(atPath: root.path).sorted() == before)
        #expect(!files.fileExists(atPath: root.appendingPathComponent("retired-2026-11-20").path), "no folder made for nothing")
    }

    @Test func testNothingThereMakesNoFolder() throws {
        try write("sessions.json")
        #expect(RetiredFiles.moveAside(in: root, on: day, files: files) { _ in }.isEmpty)
        #expect(try files.contentsOfDirectory(atPath: root.path) == ["sessions.json"])
    }

    @Test func testOneAlreadyRetiredThatDayIsLeftWhereItIs() throws {
        try write("retired-2026-11-19/runner.json", "first")
        try write("runner.json", "second")
        try write("hosts.jsonl", "hosts")
        var said: [String] = []
        #expect(RetiredFiles.moveAside(in: root, on: day, files: files) { said.append($0) } == ["hosts.jsonl"])
        #expect(text("retired-2026-11-19/runner.json") == "first", "never written over")
        #expect(text("runner.json") == "second", "left where it is")
        #expect(said.contains { $0.contains("runner.json left where it is") })
    }

    @Test @MainActor func testAServerStartingMovesThemAside() throws {
        try write("github-proxy-ca.pem", "ca")
        try write("notes.txt", "mine")
        TestPlatform.install()
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        let server = VisorServer(port: ServerTestCase.freePort())
        defer { server.stop() }
        #expect(text("github-proxy-ca.pem") == nil)
        #expect(text("retired-\(RetiredFiles.day(Date()))/github-proxy-ca.pem") == "ca", "today's folder")
        #expect(text("notes.txt") == "mine")
    }
}
}
