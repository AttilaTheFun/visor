import Foundation
import VisorServer
import VisorSystem
import Testing

extension ServerTests {
@Suite @MainActor final class ToolPathTests {
    init() { TestPlatform.install() }

    /// A wrapper on the server's own PATH is the tool, ahead of the one in
    /// the usual directories.
    @Test func testAToolOnTheServersPathComesFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tools-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wrapper = folder.appendingPathComponent("env")
        try Data("#!/bin/sh\nexec /usr/bin/env \"$@\"\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        let path = ProcessInfo.processInfo.environment["PATH"]
        defer { if let path { setenv("PATH", path, 1) } else { unsetenv("PATH") } }
        setenv("PATH", "relative/bin:\(folder.path):/usr/bin:/bin", 1)
        #expect(ToolPath.resolve("env") == wrapper.path)
    }

    /// An agent's PATH keeps the server's first, as it is, and adds each
    /// tool directory it lacks once after it.
    @Test func testAnAgentsPathKeepsTheServersFirst() {
        #expect(ToolPath.searchPath("/wrappers:/usr/bin", then: ["/opt/homebrew/bin", "/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"],
                                           separator: ":") == "/wrappers:/usr/bin:/opt/homebrew/bin:/usr/local/bin")
        let path = ServerPlatform.current.tools.environment(["PATH": "/wrappers:/usr/bin"])["PATH"] ?? ""
        let parts = path.split(separator: ":").map(String.init)
        #expect((Array(parts.prefix(2))) == ["/wrappers", "/usr/bin"])
        #expect(parts.count == Set(parts).count, "each directory once: \(path)")
    }
}
}
