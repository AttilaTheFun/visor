// Where a session's turn stands, as the chat's line under the thread and
// the sessions list say it: the words for each state, the server's state
// taken from `ephemeral` and `turn`, a message just sent shown as sending,
// a server from before turn states read from busy and the rest, and a
// reply's streamed words never drawn.

@testable import VisorClient
import VisorProtocol
import XCTest

@MainActor
final class TurnStateTests: XCTestCase {
    private func tool(_ id: String, _ label: String, _ work: StatusItem.Kind = .shell) -> TurnWait {
        TurnWait(kind: .tool, id: id, label: label, work: work)
    }

    private func subagent(_ id: String, _ label: String) -> TurnWait { TurnWait(kind: .subagent, id: id, label: label, work: .subagent) }

    func testEachStateHasItsWords() {
        XCTAssertNil(TurnState.idle.words)
        XCTAssertEqual(TurnState(.sending).words, "Sending…")
        XCTAssertEqual(TurnState(.thinking).words, "Thinking…")
        XCTAssertEqual(TurnState(.responding).words, "Responding…")
        XCTAssertEqual(TurnState(.waiting, waits: [tool("t1", "Bash: bazel test //tests:linux")]).words, "Running Bash: bazel test //tests:linux")
        XCTAssertEqual(TurnState(.waiting, waits: [tool("t1", "Bash: ls"), tool("t2", "Read: README.md", .tool)]).words, "Running Bash: ls and 1 more")
        XCTAssertEqual(TurnState(.waiting, waits: [subagent("a", "Review the diff")]).words, "Waiting for a subagent: Review the diff")
        XCTAssertEqual(TurnState(.waiting, waits: [subagent("a", "Review"), subagent("b", "Check")]).words, "Waiting for 2 subagents")
        XCTAssertEqual(TurnState(.waiting, waits: [tool("t1", "Bash: ls"), subagent("a", "Review")]).words, "Running Bash: ls and 1 more")
        XCTAssertEqual(TurnState(.waiting, waits: [TurnWait(kind: .approval, id: "p", label: "rm -rf build")]).words, "Waiting for approval")
        XCTAssertEqual(TurnState(.waiting, waits: [TurnWait(kind: .question, id: "q", label: "Which way?")]).words, "Waiting for your answer")
        XCTAssertEqual(TurnState(.waiting, waits: [TurnWait(kind: .signIn, id: "sign-in", label: "Claude")]).words, "Waiting for sign-in")
        XCTAssertEqual(TurnState(.waiting, waits: [TurnWait(kind: .background, id: "b", label: "CI checks on PR #92", work: .monitor)]).words,
                       "Waiting on CI checks on PR #92")
        XCTAssertEqual(TurnState(.waiting, waits: [TurnWait(kind: .background, id: "b", label: "CI checks", work: .monitor),
                                                   TurnWait(kind: .background, id: "c", label: "sleep 300", work: .shell)]).words,
                       "Waiting on CI checks and 1 more")
        // Its symbol's work: a tool call's or background task's, else none.
        XCTAssertEqual(TurnState(.waiting, waits: [tool("t1", "Bash: ls")]).work, .shell)
        XCTAssertNil(TurnState(.thinking).work)
    }

    func testTheServersStateIsTakenFromEphemeralAndTurn() {
        let t = SessionTranscript()
        var state = Envelope.ephemeral(session: "s", turn: TurnState(.thinking), status: [], activity: nil, busy: true,
                                       approval: nil, queued: [], notice: nil)
        state = Envelope.decode(state.encoded()) ?? state
        t.apply(state)
        XCTAssertEqual(t.turnState, TurnState(.thinking))
        let running = TurnState(.waiting, waits: [tool("t1", "Bash: swift test")])
        t.apply(Envelope.decode(Envelope.turn(session: "s", running).encoded()) ?? .turn(session: "s", running))
        XCTAssertEqual(t.turnState, running)
        XCTAssertEqual(t.turnState.words, "Running Bash: swift test")
        t.apply(.turn(session: "s", .idle))
        XCTAssertNil(t.turnState.words)
    }

    /// A server before turn states: its busy, status lines, approval and
    /// the session's background say where the turn stands, by the same
    /// precedence; its streamed words are passed over.
    func testAServerBeforeTurnStatesIsReadFromWhatItSays() {
        let t = SessionTranscript()
        t.apply(.ephemeral(session: "s", turn: .idle, status: [], activity: nil, busy: false, approval: nil, queued: [], notice: nil))
        // An ephemeral without `turn`, as 0.64.1's.
        var old = Envelope(type: "ephemeral")
        old.session = "s"; old.busy = true; old.status = []
        t.apply(old)
        XCTAssertEqual(t.turnState, TurnState(.thinking))
        var delta = Envelope(type: "delta")
        delta.session = "s"; delta.id = "M"; delta.text = "Partial words"
        t.apply(delta)
        XCTAssertEqual(t.turnState, TurnState(.thinking), "a delta is no state of its own from an old server")
        XCTAssertEqual(t.shownIDs, [], "nor is it drawn")
        var status = Envelope(type: "status")
        status.status = [StatusItem(id: "t1", kind: .shell, label: "Bash: ls", running: true)]
        t.apply(status)
        XCTAssertEqual(t.turnState.words, "Running Bash: ls")
        var asked = Envelope(type: "approval")
        asked.approval = ApprovalRequest(id: "p", tool: "Bash", summary: "rm -rf build")
        t.apply(asked)
        XCTAssertEqual(t.turnState.words, "Waiting for approval", "an approval comes first")
    }

    /// A message put in the thread for an idle agent is sending until the
    /// server says the turn has moved on.
    func testAMessageJustSentIsSendingUntilTheServerSaysMore() {
        let t = SessionTranscript()
        t.apply(.ephemeral(session: "s", turn: .idle, status: [], activity: nil, busy: false, approval: nil, queued: [], notice: nil))
        let sent = TranscriptEntry(id: "sending-1", role: .user, text: "Run the tests")
        var out = SessionTranscript.Outgoing(id: sent.id, entry: sent, sinceRevision: 0)
        out.shown = true
        t.sending.append(out)
        XCTAssertEqual(t.turnState, TurnState(.sending))
        t.apply(.turn(session: "s", TurnState(.sending)))
        XCTAssertEqual(t.turnState, TurnState(.sending))
        t.apply(.turn(session: "s", TurnState(.thinking)))
        XCTAssertEqual(t.turnState, TurnState(.thinking))
        // The turn ends before the record carries the message: idle, not
        // sending again.
        t.apply(.turn(session: "s", .idle))
        XCTAssertEqual(t.turnState, .idle)
        // One queued for a working agent is the composer's, not sending.
        let queued = TranscriptEntry(id: "sending-2", role: .user, text: "And then lint")
        t.sending.append(.init(id: queued.id, entry: queued, sinceRevision: 0))
        XCTAssertEqual(t.turnState, .idle)
    }

    /// The list's line: the server's turn, or from an older one, busy,
    /// the approval and the background.
    func testAListedSessionsTurnRoundTripsAndIsLeftOutWhenIdle() {
        var info = SessionInfo(id: "s", agent: .claude, cwd: "/tmp", title: "S", busy: true, created: 0)
        info.turn = TurnState(.waiting, waits: [subagent("a", "Review"), subagent("b", "Check")])
        XCTAssertEqual(SessionInfo(json: info.json)?.turn, info.turn)
        info.turn = .idle
        XCTAssertNil(SessionInfo(json: info.json)?.turn, "idle is left out")
        XCTAssertNil(TurnState(json: .object(["phase": .string("dreaming")])), "a phase not heard of is none")
    }
}
