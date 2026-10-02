extension StatusItem {
    var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "kind": .string(kind.rawValue), "label": .string(label), "running": .bool(running)]
        if !tasks.isEmpty { o["tasks"] = .array(tasks.map { .object(["title": .string($0.title), "state": .string($0.state.rawValue)]) }) }
        return .object(o)
    }

    init?(json: JSONValue) {
        guard let id = json["id"].string, let kind = json["kind"].string.flatMap(Kind.init(rawValue:)), let label = json["label"].string else { return nil }
        let tasks = json["tasks"].array?.compactMap { task -> TaskItem? in
            guard let title = task["title"].string, let state = task["state"].string.flatMap(TaskItem.State.init(rawValue:)) else { return nil }
            return TaskItem(title: title, state: state)
        } ?? []
        self.init(id: id, kind: kind, label: label, running: json["running"].bool ?? false, tasks: tasks)
    }
}
