// What a turn is doing, as its events say: one item per thing, running
// until its result comes, the task list as last written; nothing once
// the turn ends. Ephemeral — held here, sent over the socket, never
// written down.

import Foundation
import VisorProtocol

struct TurnStatus: Equatable {
    private(set) var items: [StatusItem] = []

    mutating func thinking(_ on: Bool) {
        items.removeAll { $0.kind == .thinking }
        if on { items.append(StatusItem(id: "thinking", kind: .thinking, label: "Thinking…", running: true)) }
    }

    mutating func started(id: String, name: String, label: String, tasks: [TaskItem]?) {
        thinking(false)
        if let tasks {
            // The list as it stands replaces the last one written.
            items.removeAll { $0.kind == .tasks }
            items.append(StatusItem(id: "tasks", kind: .tasks, label: label, running: false, tasks: tasks))
            return
        }
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].label = label
            items[index].running = true
        } else {
            items.append(StatusItem(id: id, kind: Self.kind(of: name), label: label, running: true))
        }
    }

    mutating func finished(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].running = false
    }

    mutating func clear() { items = [] }

    /// A tool's kind, by the names the agents use.
    static func kind(of name: String) -> StatusItem.Kind {
        switch name {
        case "Bash", "bash", "shell", "Shell", "commandExecution": .shell
        case "Monitor", "TaskOutput": .monitor
        case "Agent", "Task", "agent": .subagent
        default: .tool
        }
    }

    /// The task list a tool call writes, for the tools that write one:
    /// Claude Code's TodoWrite carries the whole list each time.
    static func tasks(named name: String, input: [String: Any]?) -> [TaskItem]? {
        guard name == "TodoWrite", let todos = input?["todos"] as? [[String: Any]] else { return nil }
        return todos.compactMap { todo in
            guard let content = todo["content"] as? String else { return nil }
            let state: TaskItem.State
            switch todo["status"] as? String {
            case "completed": state = .done
            case "in_progress": state = .active
            default: state = .pending
            }
            let active = todo["activeForm"] as? String
            return TaskItem(title: state == .active ? (active ?? content) : content, state: state)
        }
    }
}
