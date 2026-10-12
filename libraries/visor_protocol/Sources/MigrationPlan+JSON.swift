extension MigrationPlan {
    public var json: JSONValue {
        .object(["id": .string(id), "cwd": .string(cwd), "agentInstalled": .bool(agentInstalled), "steps": .array(steps.map(\.json))])
    }

    public init?(json: JSONValue) {
        guard let id = json["id"].string, let cwd = json["cwd"].string else { return nil }
        self.init(id: id, cwd: cwd, agentInstalled: json["agentInstalled"].bool ?? false,
                  steps: (json["steps"].array ?? []).compactMap(MigrationStep.init(json:)))
    }
}
