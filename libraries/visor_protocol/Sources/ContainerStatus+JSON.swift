extension ContainerStatus {
    public var json: JSONValue {
        var o: [String: JSONValue] = ["type": .string("container"), "state": .string(state.rawValue), "enabled": .bool(enabled),
                                      "canRun": .bool(canRun), "processes": .number(Double(processes)),
                                      "errors": .array(errors.map { .string($0) })]
        if let cpus { o["cpus"] = .number(Double(cpus)) }
        if let memoryGiB { o["memoryGiB"] = .number(Double(memoryGiB)) }
        if let idleMinutes { o["idleMinutes"] = .number(Double(idleMinutes)) }
        if let image { o["image"] = .string(image) }
        if let since { o["since"] = .number(since) }
        if let relayPort { o["relayPort"] = .number(Double(relayPort)) }
        if let egress { o["egress"] = .string(egress) }
        if let held { o["held"] = .string(held) }
        return .object(o)
    }

    /// Nil for what isn't one (no state it knows).
    public init?(json: JSONValue) {
        guard let state = json["state"].string.flatMap(ContainerState.init(rawValue:)) else { return nil }
        self.init(state: state, enabled: json["enabled"].bool ?? false, canRun: json["canRun"].bool ?? false, cpus: json["cpus"].int,
                  memoryGiB: json["memoryGiB"].int, idleMinutes: json["idleMinutes"].int, image: json["image"].string,
                  since: json["since"].double, processes: json["processes"].int ?? 0, relayPort: json["relayPort"].int,
                  egress: json["egress"].string, errors: json["errors"].array?.compactMap(\.string) ?? [],
                  held: json["held"].string)
    }
}
