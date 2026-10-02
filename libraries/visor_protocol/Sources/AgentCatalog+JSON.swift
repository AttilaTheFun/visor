extension AgentCatalog {
    var json: JSONValue {
        var o: [String: JSONValue] = ["agent": .string(agent.rawValue), "models": .array(models.map(\.json)), "available": .bool(available)]
        if let defaultModel { o["defaultModel"] = .string(defaultModel) }
        if let note { o["note"] = .string(note) }
        return .object(o)
    }

    init?(json: JSONValue) {
        guard let agent = json["agent"].string.flatMap(AgentKind.init(wire:)) else { return nil }
        self.init(agent: agent, models: json["models"].array?.compactMap(AgentModel.init(json:)) ?? [],
                  defaultModel: json["defaultModel"].string, available: json["available"].bool ?? true,
                  note: json["note"].string)
    }
}
