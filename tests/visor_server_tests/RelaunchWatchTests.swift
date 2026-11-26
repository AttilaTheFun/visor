// One update's watch at a time (RelaunchWatchLock; NCH's check of #491): a
// restart or an update asked while a live watcher holds the lock is refused
// with 409 and how long the watch has left; one whose watcher is gone, or
// whose pid another process has reused since (NCH's check of #537), is let
// through.

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
        // This process stands for a live watcher, the lock saying when it
        // started.
        let started = try #require(ServerPlatform.current.processes.startTime(of: getpid()), "the system says when it started")
        try Data("\(getpid()) \(started)\n".utf8).write(to: RelaunchWatchLock.url)
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

    /// A lock left behind whose pid another process has since: that one
    /// started long after the watcher the lock records, so it holds
    /// nothing, and a restart goes on (NCH's check of #537).
    @Test func aReusedPidDoesntBlockARestart() async throws {
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["30"]
        try other.run()
        defer { other.terminate() }
        let pid = other.processIdentifier
        let processes = ServerPlatform.current.processes
        let started = try #require(processes.startTime(of: pid), "the system says when it started")
        #expect(abs(started - Int(Date().timeIntervalSince1970)) <= 5)
        #expect(processes.startTime(of: 999_999) == nil, "no such process: not said")
        // Its watcher recorded starting ten minutes ago: within the
        // longest watch, so a live pid alone would refuse.
        let lock = "\(pid) \(started - 600)\n"
        try Data(lock.utf8).write(to: RelaunchWatchLock.url)
        #expect(RelaunchWatchLock.remaining(lock, now: started, isRunning: { _ in true }) != nil, "a live pid alone would have held it")
        #expect(server.relaunchWatched() == nil, "another process's now: it holds nothing")
        let answer = await restart(#"{"type":"restart"}"#)
        #expect(answer.status == 400 && answer.body.contains("not in tests"), "on to the platform's relaunch: \(answer.status) \(answer.body)")
        // The same pid, the lock saying when it really started: its watch.
        try Data("\(pid) \(started)\n".utf8).write(to: RelaunchWatchLock.url)
        #expect(server.relaunchWatched()?.contains("still being watched") == true)
        #expect(RelaunchWatchLock.isWatcher(pid, recorded: started + RelaunchWatchLock.tolerance, isRunning: { _ in true }, started: { _ in started }))
        #expect(!RelaunchWatchLock.isWatcher(pid, recorded: started + RelaunchWatchLock.tolerance + 1, isRunning: { _ in true },
                                             started: { _ in started }))
        #expect(!RelaunchWatchLock.isWatcher(pid, recorded: started, isRunning: { _ in true }, started: { _ in nil }), "a start not said: no watcher")
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
