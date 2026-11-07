// Stop that can't be ignored: an interrupted turn that hasn't ended within
// its grace (claude stuck in a tool, as behind macOS's dialog for the
// Downloads folder on 7 Nov 2026) ends its agent, so the session is idle and
// what is queued for it goes over; a turn that ends in time is left alone.

import Foundation
@testable import VisorServer
import XCTest

/// A claude played by the test: what it is sent, kept; it ends when asked.
@MainActor
private final class SilentClaude: AgentChild {
    let output: AsyncStream<Data>
    private let speak: AsyncStream<Data>.Continuation
    let errors = AsyncStream<Data> { $0.finish() }
    let notices = AsyncStream<String> { $0.finish() }
    let exit: Task<AgentExit, Never>
    private let exited: AsyncStream<AgentExit>.Continuation
    var pid: Int32 { 1 }
    private(set) var isRunning = true
    private(set) var written: [[String: Any]] = []

    init() {
        (output, speak) = AsyncStream.makeStream()
        let (exits, exited) = AsyncStream.makeStream(of: AgentExit.self)
        self.exited = exited
        exit = Task {
            for await exit in exits { return exit }
            return AgentExit(status: 0, signaled: true)
        }
    }

    func write(_ object: [String: Any]) { written.append(object) }
    func closeInput() {}
    func end(grace: Duration) async {
        isRunning = false
        exited.finish()
        speak.finish()
    }

    func say(_ line: String) { speak.yield(Data((line + "\n").utf8)) }
}

@MainActor
final class StuckTurnTests: ServerTestCase {
    private func working() throws -> (ClaudeProcess, SilentClaude) {
        let process = ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil)
        process.interruptGrace = .milliseconds(200)
        let child = SilentClaude()
        process.adopt(child, carried: [:])
        try process.send("Write the report to Downloads")
        return (process, child)
    }

    func testAnInterruptedTurnThatDoesntEndEndsItsAgent() async throws {
        let (process, child) = try working()
        // The turn begun, then stuck in a tool.
        child.say(#"{"type":"system","subtype":"init","session_id":"s1"}"#)
        try await Task.sleep(for: .milliseconds(50))
        process.interrupt()
        XCTAssertEqual(child.written.last?["type"] as? String, "control_request", "asked first")
        for _ in 0..<100 where child.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(child.isRunning, "ended once its grace was over")
    }

    func testATurnThatEndsInTimeIsLeftAlone() async throws {
        let (process, child) = try working()
        process.interrupt()
        child.say(#"{"type":"system","subtype":"init","session_id":"s1"}"#)
        child.say(#"{"type":"result","subtype":"error_during_execution","is_error":true}"#)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(child.isRunning, "the turn ended when asked: the agent stays")
    }
}
