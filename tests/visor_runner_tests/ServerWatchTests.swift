// A front's server watched: started again with the front's command once it
// hasn't answered twice running, and not again while it comes up.

import Foundation
@testable import VisorRunner
import Testing

@Suite final class ServerWatchTests {
    @Test func testTwoUnansweredAsksStartTheServerAtMostEveryTwoMinutes() {
        var state = ServerWatch.State()
        let now = ContinuousClock.now
        let first = state.heard(answering: false, at: now)
        #expect(!first, "one is a moment")
        let half = state.heard(answering: false, at: now + .seconds(30))
        #expect(half)
        let minute = state.heard(answering: false, at: now + .seconds(60))
        #expect(!minute, "coming up")
        let later = state.heard(answering: false, at: now + .seconds(150))
        #expect(later, "still not, two minutes on")
        let answered = state.heard(answering: true, at: now + .seconds(180))
        #expect(!answered)
        #expect(state.unanswered == 0)
        let again = state.heard(answering: false, at: now + .seconds(210))
        #expect(!again, "up again: a moment again")
    }

    @Test func testAServerThatDoesntAnswerIsStartedWithTheFrontsCommand() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("visor-watch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let mark = folder.appendingPathComponent("started")
        // Nothing listens on port 1 here.
        let front = ClientProxy.Front(name: "co-tenant", port: 7440, host: "127.0.0.1", hostPort: 1, start: "touch '\(mark.path)'")
        let watch = try #require(ServerWatch(front: front, log: { _ in }))
        watch.check()
        #expect(!FileManager.default.fileExists(atPath: mark.path))
        watch.check()
        #expect(FileManager.default.fileExists(atPath: mark.path))
        #expect((ServerWatch(front: ClientProxy.Front(name: "b", port: 7441, host: "127.0.0.1", hostPort: 1), log: { _ in })) == nil, "no command, no watch")
    }
}
