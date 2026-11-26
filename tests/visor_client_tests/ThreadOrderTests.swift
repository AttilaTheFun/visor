// A thread's rows in the record's order, each shown under an id no other
// row is shown under. Replays GitHub Drive's thread of 26 November 2026, as
// its server sent it: the thread let go of after a reply, a turn of mail
// while it was, the server started again (a new generation), then the
// thread opened and a message sent. The answer taken whole gave the mail
// turn's notice and its call the ids of a notice and a call kept above
// (alike by role and words, as rows of mail are), so two rows were shown
// under each: the list drew the thread out of order, one row twice, the
// reply under the message it followed, and drew nothing more until the
// thread was opened again. And a message sent while a turn of mail runs:
// the turn's rows go above it while it waits, and the record's copy is
// shown where the record puts it.

import MessageCache
@testable import VisorClient
import VisorProtocol
import VisorServices
import XCTest

@MainActor
final class ThreadOrderTests: XCTestCase {
    private var server: ScriptedServer!
    private var host: AgentServerConnection!
    private var key: String { host.record.id + "/S" }

    override func setUp() async throws {
        try await super.setUp()
        AgentServerConnection.cache = .inMemory()
        server = ScriptedServer()
        server.answersTranscripts = true
        ScriptedProvider.server = server
        AgentServerProviders.register(ScriptedProvider())
        VisorHost.settings = MemorySettings()
        host = AgentServerConnection(record: AgentServerRecord(name: "", address: "mac.example", provider: "scripted"))
        host.connect()
        await settle()
    }

    private func settle() async {
        for _ in 0..<5 {
            for _ in 0..<20 { await Task.yield() }
            await AgentServerConnection.cacheQueue.drain()
        }
    }

    /// Waits, up to five seconds, for a condition.
    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "never came true", file: file, line: line)
    }

    static let notice = "[Visor: you have 1 unread message in your inbox; read them with read_inbox]"
    static let migrate = "Ok I'm going to migrate this session from the macbook to the mini and into one of its visor containers. "
        + "Is everything you were working on committed and pushed?"

    /// A turn of mail as the record has it: the notice, the agent's call
    /// to read its inbox (a row of a call and no words), the call's
    /// result, the reply.
    private func mailTurn(_ n: Int) -> [TranscriptEntry] {
        [TranscriptEntry(id: "user-file-notice-\(n)", role: .user, text: Self.notice),
         TranscriptEntry(id: "msg-read-\(n)", role: .assistant, text: "", activities: ["mcp__visor__read_inbox: {}"]),
         TranscriptEntry(id: "tool-file-inbox-\(n)", role: .tool, text: "Message \(n) from Shireworks", toolName: "tool_result"),
         TranscriptEntry(id: "msg-reply-\(n)", role: .assistant, text: "Reply to message \(n).")]
    }

    /// The thread as the screen shows it (AgentScreen's rows): the record's
    /// rows under their display ids, what was sent and is shown, what the
    /// agent was handed and has not written.
    private func thread(_ t: SessionTranscript) -> [String] {
        t.entries.map(t.displayID(of:)) + t.sending.filter(\.shown).map(\.id) + t.deliveredEntries.map(\.id)
    }

    private func assertEachShownOnce(_ t: SessionTranscript, file: StaticString = #filePath, line: UInt = #line) {
        let ids = thread(t)
        let twice = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        XCTAssertEqual(twice, [], "ids shown twice", file: file, line: line)
    }

    private func delta(_ rows: [TranscriptEntry], after: [String], revision: Int, generation: Int) -> Envelope {
        var e = Envelope.transcript(session: "S", entries: rows, streaming: "", activity: nil, busy: true, error: nil)
        e.after = after; e.removed = []
        e.revision = revision; e.generation = generation; e.more = true
        return e
    }

    func testAThreadOpenedAfterTheServerStartedAgainShowsEachRowOnceInTheRecordsOrder() async throws {
        // Last seen by this device: 29 turns of mail, then the person's
        // message and the reply to it (revision 40 of the server's run then).
        let archive = [TranscriptEntry(id: "user-file-archive", role: .user, text: "archive update_kit and shake_kit"),
                       TranscriptEntry(id: "msg-archive-calls", role: .assistant, text: "", activities: ["Bash: gh repo archive"]),
                       TranscriptEntry(id: "tool-file-archive", role: .tool, text: "archived", toolName: "tool_result"),
                       TranscriptEntry(id: "msg-archived", role: .assistant, text: "I've archived update_kit and shake_kit on GitHub.")]
        let seen = (0..<29).flatMap(mailTurn) + archive
        try AgentServerConnection.cache.replace(key, with: seen)
        try AgentServerConnection.cache.setSyncState(SyncState(revision: 40, generation: 1), for: key)

        // A turn of mail while the thread was let go of; the server then
        // started again, in generation 2, its record these 124 rows.
        let mail = [TranscriptEntry(id: "user-file-ca016354", role: .user, text: Self.notice),
                    TranscriptEntry(id: "msg-q4PkM7Bu", role: .assistant, text: "", activities: ["mcp__visor__read_inbox: {}"]),
                    TranscriptEntry(id: "tool-file-96119e35", role: .tool, text: "Message from Shireworks", toolName: "tool_result"),
                    TranscriptEntry(id: "msg-G7vtWaqq", role: .assistant, text: "Shireworks agrees: nothing of its needs either repo writable.")]
        let record = seen + mail

        let t = host.transcript(for: "S")
        host.subscribe("S")
        XCTAssertEqual(t.entries.map(\.id), Array(seen.suffix(AgentServerConnection.initialRows)).map(\.id), "as kept, at once")
        let notedBefore = ConnectionLog.shared.lines.count

        // Asked past revision 40 of generation 1: the whole, the record's
        // last 100 rows, after the row before them (one this device holds).
        var whole = Envelope.transcript(session: "S", entries: Array(record.suffix(100)), streaming: "", activity: nil, busy: false, error: nil)
        whole.reset = true; whole.follows = record[record.count - 101].id
        whole.revision = 1; whole.generation = 2; whole.more = true
        server.transcriptAnswers = [whole]
        await until { t.generation == 2 }
        XCTAssertEqual(server.transcriptAsks.first?.since, 40)
        XCTAssertEqual(server.transcriptAsks.first?.generation, 1)
        assertEachShownOnce(t)
        XCTAssertEqual(thread(t).suffix(5), ["msg-archived", "user-file-ca016354", "msg-q4PkM7Bu", "tool-file-96119e35", "msg-G7vtWaqq"],
                       "the mail turn's rows under their own ids, after the rows before them")
        XCTAssertFalse(ConnectionLog.shared.lines.dropFirst(notedBefore).contains { $0.contains("shown twice") })

        // Sent to the agent, idle: in the thread at once, after the reply.
        var busy = SessionInfo(id: "S", agent: .claude, cwd: "/Users/logan/Developer", title: "GitHub Drive", busy: true, created: 0)
        busy.delivered = [Self.migrate]
        server.sendAnswer = [busy]
        host.sendMessage("S", text: Self.migrate)
        let sent = try XCTUnwrap(t.sending.first?.id)
        await until { server.sent.count == 1 }
        XCTAssertEqual(thread(t).suffix(2), ["msg-G7vtWaqq", sent])

        // The agent's log has it, then the reply and its call's result.
        let message = TranscriptEntry(id: "user-file-d3257122", role: .user, text: Self.migrate)
        let reply = TranscriptEntry(id: "msg-sW9qk6rc", role: .assistant, text: "I'll check every checkout I worked in for uncommitted changes:",
                                    activities: ["Bash: git status"])
        let result = TranscriptEntry(id: "tool-file-d53935bd", role: .tool, text: "clean", toolName: "tool_result")
        server.transcriptAnswers = [delta([message], after: ["msg-G7vtWaqq"], revision: 2, generation: 2)]
        await until { t.revision == 2 }
        XCTAssertTrue(t.sending.isEmpty)
        XCTAssertEqual(thread(t).suffix(2), ["msg-G7vtWaqq", sent], "the record's copy, where the record puts it, under the sent row's id")
        server.transcriptAnswers = [delta([reply], after: [message.id], revision: 3, generation: 2),
                                    delta([result], after: [reply.id], revision: 4, generation: 2)]
        await until { t.revision == 4 }
        let after = record + [message, reply, result]
        XCTAssertEqual(t.entries.map(\.id), Array(after.suffix(t.entries.count)).map(\.id), "the record's order")
        XCTAssertEqual(thread(t).suffix(4), ["msg-G7vtWaqq", sent, "msg-sW9qk6rc", "tool-file-d53935bd"])
        assertEachShownOnce(t)
        XCTAssertFalse(ConnectionLog.shared.lines.dropFirst(notedBefore).contains { $0.contains("shown twice") })

        // Kept as the record has it: opened again, the thread is the same.
        await settle()
        XCTAssertEqual(AgentServerConnection.cache.messages(in: key, limit: 1 << 20).messages.map(\.id), after.map(\.id))
        host.leave("S")
        host.release("S")
        XCTAssertTrue(host.transcript(for: "S") === t)
        XCTAssertEqual(t.entries.map(\.id), Array(after.suffix(AgentServerConnection.initialRows)).map(\.id))
        assertEachShownOnce(t)
    }

    /// Sent while a turn of mail runs, from a client that had not heard of
    /// the turn yet: the message is shown (the server queued it), the
    /// turn's rows arrive above it, and once the turn ends and the message
    /// goes over, the record's copy is shown where the record puts it.
    func testAMessageSentDuringATurnOfMailWaitsBelowTheTurnsRows() async throws {
        let earlier = (0..<3).flatMap(mailTurn)
        let t = host.transcript(for: "S")
        host.subscribe("S")
        var whole = Envelope.transcript(session: "S", entries: earlier, streaming: "", activity: nil, busy: false, error: nil)
        whole.reset = true; whole.follows = ""; whole.revision = 1; whole.generation = 5; whole.more = false
        server.transcriptAnswers = [whole]
        await until { t.loaded && t.revision == 1 }

        // The notice starts the turn; the client has the row, not yet the turn.
        let notice = TranscriptEntry(id: "user-file-ca016354", role: .user, text: Self.notice)
        server.transcriptAnswers = [delta([notice], after: ["msg-reply-2"], revision: 2, generation: 5)]
        await until { t.revision == 2 }

        // The server queues it: the turn of mail runs.
        var queued = SessionInfo(id: "S", agent: .claude, cwd: "/Users/logan/Developer", title: "GitHub Drive", busy: true, created: 0)
        queued.queued = [Self.migrate]
        server.sendAnswer = [queued]
        host.sendMessage("S", text: Self.migrate)
        let sent = try XCTUnwrap(t.sending.first?.id)
        await until { server.sent.count == 1 }
        XCTAssertEqual(t.sending.map(\.shown), [true], "shown, as sent to an agent that looked idle")
        XCTAssertEqual(thread(t).suffix(2), [notice.id, sent])

        // The turn's own rows: above the message, which stays last.
        let read = TranscriptEntry(id: "msg-q4PkM7Bu", role: .assistant, text: "", activities: ["mcp__visor__read_inbox: {}"])
        let inbox = TranscriptEntry(id: "tool-file-96119e35", role: .tool, text: "Message from Shireworks", toolName: "tool_result")
        let agrees = TranscriptEntry(id: "msg-G7vtWaqq", role: .assistant, text: "Shireworks agrees: nothing of its needs either repo writable.")
        server.transcriptAnswers = [delta([read, inbox], after: [notice.id, read.id], revision: 3, generation: 5),
                                    delta([agrees], after: [inbox.id], revision: 4, generation: 5)]
        await until { t.revision == 4 }
        XCTAssertEqual(thread(t).suffix(5), [notice.id, read.id, inbox.id, agrees.id, sent])
        XCTAssertEqual(t.sending.count, 1, "still on its way")

        // Handed over once the turn ended: the agent has it, its log not
        // yet. Shown once, as sent.
        var handed = SessionInfo(id: "S", agent: .claude, cwd: "/Users/logan/Developer", title: "GitHub Drive", busy: true, created: 0)
        handed.delivered = [Self.migrate]
        t.info = handed
        XCTAssertEqual(thread(t).suffix(2), [agrees.id, sent])

        // The log has it, after the reply to the mail: where the record
        // puts it, under the sent row's id; then the reply to it, below.
        let message = TranscriptEntry(id: "user-file-d3257122", role: .user, text: Self.migrate)
        let reply = TranscriptEntry(id: "msg-sW9qk6rc", role: .assistant, text: "I'll check every checkout I worked in.")
        server.transcriptAnswers = [delta([message], after: [agrees.id], revision: 5, generation: 5),
                                    delta([reply], after: [message.id], revision: 6, generation: 5)]
        await until { t.revision == 6 }
        XCTAssertTrue(t.sending.isEmpty)
        XCTAssertEqual(t.entries.map(\.id), (earlier + [notice, read, inbox, agrees, message, reply]).map(\.id))
        XCTAssertEqual(thread(t).suffix(3), [agrees.id, sent, reply.id])
        assertEachShownOnce(t)
    }

    /// A row that went, whose id a new row like it took, comes back with a
    /// page of earlier rows: each is shown under an id of its own.
    func testARowThatCameBackIsNotShownUnderTheIdOfOneLikeIt() {
        let t = SessionTranscript()
        var first = Envelope(type: "transcript")
        first.entries = mailTurn(0) + mailTurn(1)
        first.reset = true; first.revision = 1; first.generation = 1
        t.sync(first)
        // Another generation, from the second turn on (its first row
        // follows one not held): the first turn went; the third's notice
        // and call take the ids of the first's.
        var second = Envelope(type: "transcript")
        second.entries = mailTurn(1) + mailTurn(2)
        second.reset = true; second.follows = "elsewhere"; second.revision = 1; second.generation = 2
        t.sync(second)
        XCTAssertEqual(t.displayID(of: t.entries[4]), "user-file-notice-0")
        assertEachShownOnce(t)
        // The first turn read again, as earlier rows.
        t.putEarlier(mailTurn(0), more: false)
        XCTAssertEqual(t.entries.first?.id, "user-file-notice-0")
        assertEachShownOnce(t)
        XCTAssertEqual(t.displayID(of: t.entries[0]), "user-file-notice-0")
    }
}
