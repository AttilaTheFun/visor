// The turn's status as the wire carries it, as the chat shows it.

import AgentUI
import VisorProtocol

extension ActivityItem {
    init(_ item: StatusItem) {
        let kind: Kind
        switch item.kind {
        case .thinking: kind = .thinking
        case .shell: kind = .shell
        case .monitor: kind = .monitor
        case .subagent: kind = .subagent
        case .tool: kind = .tool
        case .tasks: kind = .tasks
        }
        self.init(id: item.id, kind: kind, label: item.label, running: item.running, tasks: item.tasks.map { task in
            let state: ActivityTask.State
            switch task.state {
            case .pending: state = .pending
            case .active: state = .active
            case .done: state = .done
            }
            return ActivityTask(title: task.title, state: state)
        })
    }
}
