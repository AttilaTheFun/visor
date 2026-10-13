extension MigrationStep {
    public var json: JSONValue {
        .object(["project": .string(project), "path": .string(path), "action": .string(action.rawValue), "note": .string(note),
                 "chosen": .bool(chosen)])
    }

    public init?(json: JSONValue) {
        guard let project = json["project"].string, let path = json["path"].string,
              let action = json["action"].string.flatMap(Action.init(rawValue:)) else { return nil }
        self.init(project: project, path: path, action: action, note: json["note"].string ?? "", chosen: json["chosen"].bool ?? false)
    }
}
