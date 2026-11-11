extension RunnerHello {
    public var json: JSONValue {
        .object(["type": .string("runner"), "protocol": .number(Double(protocolVersion)), "id": .string(id), "name": .string(name), "kind": .string(kind.rawValue),
                 "agents": .array(agents.map { .string($0.rawValue) }), "capacity": .number(Double(capacity)),
                 "running": .number(Double(running)), "labels": .array(labels.map(JSONValue.string)),
                 "sessions": .object(sessions.mapValues(JSONValue.string))])
    }

    /// Nil for anything but a runner's hello, or one missing what it must say.
    /// Agents of kinds this build doesn't know are left out.
    public init?(json: JSONValue) {
        guard json["type"].string == "runner", let id = json["id"].string, !id.isEmpty,
              let kind = json["kind"].string.flatMap(Kind.init(rawValue:)), let capacity = json["capacity"].int else { return nil }
        self.init(id: id, name: json["name"].string ?? id, kind: kind,
                  agents: (json["agents"].array ?? []).compactMap { $0.string.flatMap(AgentKind.init(rawValue:)) },
                  capacity: capacity, running: json["running"].int ?? 0, labels: (json["labels"].array ?? []).compactMap(\.string),
                  sessions: (json["sessions"].object ?? [:]).compactMapValues(\.string), protocolVersion: json["protocol"].int ?? Self.protocolVersion)
    }
}
