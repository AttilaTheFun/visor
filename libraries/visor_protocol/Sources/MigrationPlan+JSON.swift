extension MigrationPlan {
    public var json: JSONValue {
        .object(["id": .string(id), "cwd": .string(cwd), "agentInstalled": .bool(agentInstalled)])
    }

    /// A plan as JSON has it. A server before 0.61 also gave a `step` per
    /// project, which are passed over.
    public init?(json: JSONValue) {
        guard let id = json["id"].string, let cwd = json["cwd"].string else { return nil }
        self.init(id: id, cwd: cwd, agentInstalled: json["agentInstalled"].bool ?? false)
    }
}
