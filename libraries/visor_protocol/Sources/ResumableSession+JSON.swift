extension ResumableSession {
    var json: JSONValue {
        .object(["id": .string(id), "agent": .string(agent.rawValue), "cwd": .string(cwd), "title": .string(title), "timestamp": .number(timestamp)])
    }

    public init?(json: JSONValue) {
        guard let id = json["id"].string, let agent = json["agent"].string.flatMap(AgentKind.init(wire:)) else { return nil }
        self.init(id: id, agent: agent, cwd: json["cwd"].string ?? "", title: json["title"].string ?? "", timestamp: json["timestamp"].double ?? 0)
    }
}
