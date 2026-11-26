// What a session's row shows at the end of its first line: a raised hand
// while it waits to be allowed something, a question while it waits for an
// answer (before the turn they hold up, so a session waiting on the person
// is seen without opening it); else a spinner while the agent works
// (thinking, writing, running a tool call of its own), a clock while it
// waits on anything else — a subagent, a monitor, work left in the
// background. A monitor is one more thing waited on, not a mark of its own.

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

    func testAPromptOrAQuestionShowsWhileItsTurnGoesOn() {
        let prompt = ApprovalRequest(id: "p", tool: "Bash", summary: "rm -rf build")
        let question = ApprovalRequest(id: "q", tool: "AskUserQuestion", summary: "",
                                       questions: [AgentQuestion(question: "Which?", options: [.init(label: "This")])])
        XCTAssertEqual(SessionCardRow.activity(of: session(busy: true, approval: prompt)), .approval)
        XCTAssertEqual(SessionCardRow.activity(of: session(busy: true, approval: question)), .question)
        XCTAssertEqual(SessionCardRow.activity(of: session(approval: question)), .question, "a question Codex asked between turns")
        // As the turn's state says them, from a server of turn states.
        let asked = TurnState(.waiting, waits: [TurnWait(kind: .approval, id: "p", label: "rm -rf build")])
        let questioned = TurnState(.waiting, waits: [TurnWait(kind: .question, id: "q", label: "Which?")])
        XCTAssertEqual(SessionCardRow.activity(of: session(busy: true, turn: asked)), .approval)
        XCTAssertEqual(SessionCardRow.activity(of: session(busy: true, turn: questioned)), .question)
        // A sign-in waits on the person too, but is one more wait.
        let signIn = TurnState(.waiting, waits: [TurnWait(kind: .signIn, id: "sign-in", label: "Claude")])
        XCTAssertEqual(SessionCardRow.activity(of: session(busy: true, turn: signIn)), .waiting)
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
