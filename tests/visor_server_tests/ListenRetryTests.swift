// A port that is taken when the server starts — the server it replaces
// still letting go of it, as on 2 Nov 2026 — is tried again for a few
// seconds: the server listens once the port is free, rather than run on
// with no way in.

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
@testable import VisorServer
import Foundation
import Testing

extension ServerTests {
@Suite @MainActor final class ListenRetryTests {
    init() { TestPlatform.install() }

    @Test func testATakenPortIsTriedAgain() async throws {
        #if canImport(Darwin)
        // The Network framework lets two listeners share a port
        // (allowLocalEndpointReuse) and says of one it can't have only later,
        // in its state: the retry is the POSIX listener's, where a server
        // that came up with no port was seen (Linux, the co-tenant).
        try Test.cancel("POSIX listening only")
        #else
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-listen-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        VisorServer.socketPathOverride = "/tmp/visor-listen-\(getpid()).sock"
        defer { VisorServer.socketPathOverride = nil }

        let port = ServerTestCase.freePort()
        let taken = try ServerPlatform.current.listening.listen(ListeningOptions(port: port)) { $0.close() }
        let server = VisorServer(port: port)
        defer { server.stop() }
        server.password = "pearl-grove"
        #expect(!server.listening, "the port is taken")

        taken.stop()
        for _ in 0..<60 where !server.listening { try await Task.sleep(for: .milliseconds(100)) }
        #expect(server.listening, "listening once the port is free")
        #expect(server.lastError == nil)
        #endif
    }
}
}
