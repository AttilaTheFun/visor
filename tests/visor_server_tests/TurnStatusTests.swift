// The turn's status from its events: thinking comes and goes, a tool runs
// until its result, the task list stands as last written, the end clears.

@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import Foundation
import Testing

extension ServerTests {
@Suite @MainActor final class TurnStatusTests {
    init() { TestPlatform.install() }

    @Test func testItemsFollowTheEvents() {
        var turn = TurnStatus()
        turn.thinking(true)
        #expect(turn.items.map(\.kind) == [.thinking])
        turn.started(id: "t1", name: "Bash", label: "Bash: ls", tasks: nil)
        #expect(turn.items.map(\.kind) == [.shell])
        #expect((turn.items.first?.running) == true)
        turn.started(id: "t2", name: "Agent", label: "Agent: explore", tasks: nil)
        turn.finished(id: "t1")
        #expect(turn.items.map(\.running) == [false, true])
        #expect((turn.items.last?.kind) == .subagent)
        let list = TurnStatus.tasks(named: "TodoWrite", input: ["todos": [
            ["content": "Write it", "status": "completed"],
            ["content": "Test it", "activeForm": "Testing it", "status": "in_progress"],
            ["content": "Ship it", "status": "pending"],
        ]])
        turn.started(id: "t3", name: "TodoWrite", label: "Tasks", tasks: list)
        #expect((turn.items.last?.tasks.map(\.title)) == ["Write it", "Testing it", "Ship it"])
        #expect((turn.items.last?.tasks.map(\.state)) == [.done, .active, .pending])
        turn.started(id: "t4", name: "TodoWrite", label: "Tasks", tasks: [TaskItem(title: "Only", state: .done)])
        #expect((turn.items.filter { $0.kind == .tasks }.count) == 1)
        #expect(TurnStatus.tasks(named: "Bash", input: ["command": "ls"]) == nil)
        turn.clear()
        #expect(turn.items.isEmpty)
        #expect(TurnStatus.kind(of: "Monitor") == .monitor)
        #expect(TurnStatus.kind(of: "Read") == .tool)
    }
}
}
