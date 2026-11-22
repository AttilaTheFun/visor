// One update's watch at a time (RelaunchWatchLock; NCH's check of #491): a
// restart or an update asked while a live watcher holds the lock is refused
// with 409 and how long the watch has left; one whose watcher is gone is
// let through.

import Foundation
#if canImport(Glibc)
import Glibc
#endif
import VisorProtocol
@testable import VisorServer
import Testing

extension ServerTests {
@Suite @MainActor final class RelaunchWatchTests {
    private var server: VisorServer!
    private var root: URL!

    init() async throws {
        TestPlatform.install()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-relaunch-watch-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: ServerTestCase.freePort())
        server.password = "pw"
    }

    isolated deinit {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func restart(_ body: String) async -> HTTPResponse {
        let request = HTTPRequest(method: "POST", path: "/api/restart", headers: ["authorization": "Bearer pw"], body: body, trusted: false)
        return await withCheckedContinuation { done in server.route(request) { done.resume(returning: $0) } }
    }

    @Test func aRestartOrAnUpdateDuringAWatchIsRefused() async throws {
        let now = Int(Date().timeIntervalSince1970)
        // This process stands for a live watcher.
        try Data("\(getpid()) \(now - 30)\n".utf8).write(to: RelaunchWatchLock.url)
        for body in [#"{"type":"restart"}"#, #"{"type":"restart","path":"/tmp/Visor.app"}"#] {
            let answer = await restart(body)
            #expect(answer.status == 409, "\(body)")
            #expect(answer.body.contains("An update is still being watched; try again in"), "\(answer.body)")
        }
        #expect(server.relaunch(installing: nil, carrying: [])?.contains("still being watched") == true, "the menu's restart too")
        // Its watcher gone: nothing holds it.
        try Data("999999 \(now)\n".utf8).write(to: RelaunchWatchLock.url)
        #expect(server.relaunchWatched() == nil)
        try FileManager.default.removeItem(at: RelaunchWatchLock.url)
        #expect(server.relaunchWatched() == nil)
    }

    @Test func eachWatchKeepsThePreviousBuildInAFolderOfItsOwn() {
        let one = RelaunchWatchLock.backup(for: "/Applications/Visor.app", token: "aaaa1111")
        let two = RelaunchWatchLock.backup(for: "/Applications/Visor.app", token: "bbbb2222")
        #expect(one.hasSuffix("/Previous/aaaa1111/Visor.app"))
        #expect(one != two)
        #expect(RelaunchWatchLock.backup(for: "/Applications/Visor.app") != RelaunchWatchLock.backup(for: "/Applications/Visor.app"))
    }
}
}
