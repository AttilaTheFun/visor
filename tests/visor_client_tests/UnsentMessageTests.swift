// A message the computer never took stays in the thread, marked as not
// sent and why, until it is sent again or let go of; the connection log
// says so. On 26 Nov 2026 such messages left the thread with nothing said
// (the error was kept where no screen shows it), and the agents never had
// them.

@testable import VisorClient
import VisorProtocol
import VisorServices
import XCTest

@MainActor
final class UnsentMessageTests: XCTestCase {
    private func host() -> AgentServerConnection {
        ScriptedProvider.server = ScriptedServer()
        AgentServerProviders.register(ScriptedProvider())
        return AgentServerConnection(record: AgentServerRecord(name: "Mini", address: "mini.example", provider: "scripted"))
    }

    /// Waits a little while for something to come true.
    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "never came true", file: file, line: line)
    }

    func testAMessageNotTakenStaysInTheThreadSayingWhy() async throws {
        let host = host()
        let transcript = host.transcript(for: "s")
        ScriptedProvider.server.sendFailure = AgentServerError.message("no answer at the socket within 60 seconds")
        host.sendMessage("s", text: "ok images is migrating now")
        try await waitFor { transcript.sending.first?.failure != nil }
        XCTAssertEqual(transcript.sending.map(\.entry.text), ["ok images is migrating now"], "kept, its words not lost")
        XCTAssertEqual(transcript.sending.map(\.shown), [true], "in the thread")
        XCTAssertEqual(transcript.unsent.count, 1)
        XCTAssertEqual(transcript.unsentWords, "A message was not sent: no answer at the socket within 60 seconds. Send them again from Not sent.")
        XCTAssertNotEqual(transcript.turnState.phase, .sending, "not on its way: the line under the thread does not say sending")
        XCTAssertTrue(ConnectionLog.shared.lines.last?.contains("thread s: a message was not sent (26 characters)") == true,
                      ConnectionLog.shared.lines.last ?? "")
        // The agent's own failure, after: what was never sent stays.
        var failure = Envelope(type: "failure")
        failure.message = "claude exited"
        transcript.apply(failure)
        XCTAssertEqual(transcript.unsent.count, 1)
    }

    func testANotSentMessageIsSentAgainInItsOwnRow() async throws {
        let host = host()
        let transcript = host.transcript(for: "s")
        ScriptedProvider.server.sendFailure = AgentServerError.message("refused")
        host.sendMessage("s", text: "first")
        host.sendMessage("s", text: "second")
        try await waitFor { transcript.unsent.count == 2 }
        let ids = transcript.sending.map(\.id)

        ScriptedProvider.server.sendFailure = nil
        ScriptedProvider.server.sendAnswer = [SessionInfo(id: "s", agent: .claude, cwd: "/w", title: "", created: 0)]
        host.resend("s")
        XCTAssertTrue(transcript.unsent.isEmpty, "on their way again at once")
        try await waitFor { ScriptedProvider.server.sent.count == 4 }
        XCTAssertEqual(ScriptedProvider.server.sent.map { $0.1 }, ["first", "second", "first", "second"], "in the order they were said")
        XCTAssertEqual(transcript.sending.map(\.id), ids, "each in its own row still")
        XCTAssertTrue(transcript.sending.allSatisfy { $0.shown && $0.failure == nil })
    }

    func testNotSentMessagesCanBeLetGo() async throws {
        let host = host()
        let transcript = host.transcript(for: "s")
        ScriptedProvider.server.sendFailure = AgentServerError.message("refused")
        host.sendMessage("s", text: "never mind")
        try await waitFor { transcript.unsent.count == 1 }
        host.discardUnsent("s")
        XCTAssertTrue(transcript.sending.isEmpty)
        XCTAssertNil(transcript.unsentWords)
        // What is sent next goes to an idle agent, in the thread at once.
        ScriptedProvider.server.sendFailure = nil
        host.sendMessage("s", text: "and now")
        XCTAssertEqual(transcript.sending.map(\.shown), [true])
    }
}
