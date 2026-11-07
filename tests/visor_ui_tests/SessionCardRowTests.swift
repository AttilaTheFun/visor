// What a session's row shows at the end of its first line: what holds the
// agent up before the turn it holds up, so a session waiting on the person
// is seen without opening it.

import VisorProtocol
@testable import VisorUI
import XCTest

@MainActor
final class SessionCardRowTests: XCTestCase {
    private func session(busy: Bool = false, approval: ApprovalRequest? = nil, background: [StatusItem] = []) -> SessionInfo {
        var info = SessionInfo(id: "S", agent: .claude, cwd: "/tmp", title: "S", created: 0)
        info.busy = busy
        info.pendingApproval = approval
        info.background = background
        return info
    }

    func testAPromptOrAQuestionShowsWhileItsTurnGoesOn() {
        let prompt = ApprovalRequest(id: "p", tool: "Bash", summary: "rm -rf build")
        let question = ApprovalRequest(id: "q", tool: "AskUserQuestion", summary: "",
                                       questions: [AgentQuestion(question: "Which?", options: [.init(label: "This")])])
        XCTAssertEqual(SessionCardRow.activity(of: session(busy: true, approval: prompt)), .approval)
        XCTAssertEqual(SessionCardRow.activity(of: session(busy: true, approval: question)), .question)
        XCTAssertEqual(SessionCardRow.activity(of: session(approval: question)), .question, "a question Codex asked between turns")
    }

    func testOtherwiseTheTurnThenTheBackground() {
        let monitor = StatusItem(id: "m", kind: .monitor, label: "CI", running: true)
        XCTAssertEqual(SessionCardRow.activity(of: session(busy: true, background: [monitor])), .working)
        XCTAssertEqual(SessionCardRow.activity(of: session(background: [monitor])), .background)
        XCTAssertEqual(SessionCardRow.activity(of: session()), SessionCardRow.Activity.none)
    }
}
