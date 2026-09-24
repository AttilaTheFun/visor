// The turn's status from its events: thinking comes and goes, a tool runs
// until its result, the task list stands as last written, the end clears.

import VisorProtocol
@testable import VisorServer
import XCTest

final class TurnStatusTests: XCTestCase {
    func testItemsFollowTheEvents() {
        var turn = TurnStatus()
        turn.thinking(true)
        XCTAssertEqual(turn.items.map(\.kind), [.thinking])
        turn.started(id: "t1", name: "Bash", label: "Bash: ls", tasks: nil)
        XCTAssertEqual(turn.items.map(\.kind), [.shell])
        XCTAssertEqual(turn.items.first?.running, true)
        turn.started(id: "t2", name: "Agent", label: "Agent: explore", tasks: nil)
        turn.finished(id: "t1")
        XCTAssertEqual(turn.items.map(\.running), [false, true])
        XCTAssertEqual(turn.items.last?.kind, .subagent)
        let list = TurnStatus.tasks(named: "TodoWrite", input: ["todos": [
            ["content": "Write it", "status": "completed"],
            ["content": "Test it", "activeForm": "Testing it", "status": "in_progress"],
            ["content": "Ship it", "status": "pending"],
        ]])
        turn.started(id: "t3", name: "TodoWrite", label: "Tasks", tasks: list)
        XCTAssertEqual(turn.items.last?.tasks.map(\.title), ["Write it", "Testing it", "Ship it"])
        XCTAssertEqual(turn.items.last?.tasks.map(\.state), [.done, .active, .pending])
        turn.started(id: "t4", name: "TodoWrite", label: "Tasks", tasks: [TaskItem(title: "Only", state: .done)])
        XCTAssertEqual(turn.items.filter { $0.kind == .tasks }.count, 1)
        XCTAssertNil(TurnStatus.tasks(named: "Bash", input: ["command": "ls"]))
        turn.clear()
        XCTAssertTrue(turn.items.isEmpty)
        XCTAssertEqual(TurnStatus.kind(of: "Monitor"), .monitor)
        XCTAssertEqual(TurnStatus.kind(of: "Read"), .tool)
    }
}
