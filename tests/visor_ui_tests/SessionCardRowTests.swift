// What a session's row shows at the end of its first line: a spinner while
// the agent works (thinking, writing, running a tool call of its own), a
// clock while it waits on anything else — an approval, a question, a
// subagent, a monitor, work left in the background. A monitor is one more
// thing waited on, not a mark of its own.

import VisorProtocol
@testable import VisorUI
import XCTest

@MainActor
final class SessionCardRowTests: XCTestCase {
    private func session(busy: Bool = false, approval: ApprovalRequest? = nil, background: [StatusItem] = [],
                         turn: TurnState? = nil) -> SessionInfo {
        var info = SessionInfo(id: "S", agent: .claude, cwd: "/tmp", title: "S", created: 0)
        info.busy = busy
        info.pendingApproval = approval
        info.background = background
        info.turn = turn
        return info
    }

    func testAPromptOrAQuestionIsWaiting() {
        let prompt = ApprovalRequest(id: "p", tool: "Bash", summary: "rm -rf build")
        let question = ApprovalRequest(id: "q", tool: "AskUserQuestion", summary: "",
                                       questions: [AgentQuestion(question: "Which?", options: [.init(label: "This")])])
        XCTAssertEqual(SessionCardRow.activity(of: session(busy: true, approval: prompt)), .waiting)
        XCTAssertEqual(SessionCardRow.activity(of: session(busy: true, approval: question)), .waiting)
        XCTAssertEqual(SessionCardRow.activity(of: session(approval: question)), .waiting, "a question Codex asked between turns")
    }

    func testFromAServerBeforeTurnStates() {
        let monitor = StatusItem(id: "m", kind: .monitor, label: "CI", running: true)
        XCTAssertEqual(SessionCardRow.activity(of: session(busy: true, background: [monitor])), .working)
        XCTAssertEqual(SessionCardRow.activity(of: session(background: [monitor])), .waiting)
        XCTAssertEqual(SessionCardRow.activity(of: session()), SessionCardRow.Activity.none)
    }

    func testTheTurnsStateSaysWhich() {
        let tests = TurnWait(kind: .tool, id: "t", label: "Bash: swift test", work: .shell)
        let monitor = TurnWait(kind: .tool, id: "m", label: "Monitor: CI", work: .monitor)
        let subagent = TurnWait(kind: .subagent, id: "a", label: "Review", work: .subagent)
        let left = TurnWait(kind: .background, id: "b", label: "CI checks", work: .monitor)
        for phase in [TurnState.Phase.sending, .thinking, .responding] {
            XCTAssertEqual(SessionCardRow.activity(of: session(busy: true, turn: TurnState(phase))), .working, "\(phase)")
        }
        XCTAssertEqual(SessionCardRow.activity(of: session(busy: true, turn: TurnState(.waiting, waits: [tests]))), .working,
                       "a command of its own: still working")
        XCTAssertEqual(SessionCardRow.activity(of: session(busy: true, turn: TurnState(.waiting, waits: [monitor]))), .waiting)
        XCTAssertEqual(SessionCardRow.activity(of: session(busy: true, turn: TurnState(.waiting, waits: [tests, subagent]))), .waiting)
        XCTAssertEqual(SessionCardRow.activity(of: session(turn: TurnState(.waiting, waits: [left]))), .waiting)
        XCTAssertEqual(SessionCardRow.activity(of: session(turn: .idle)), SessionCardRow.Activity.none)
    }
}
