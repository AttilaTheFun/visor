extension MachineUsage {
    var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "platform": .string(platform)]
        if let config { o["config"] = .string(config) }
        if let session { o["session"] = .string(session) }
        if let cpus { o["cpus"] = .number(Double(cpus)) }
        if let cpuPercent { o["cpuPercent"] = .number(cpuPercent) }
        if let memoryLimitBytes { o["memoryLimitBytes"] = .number(Double(memoryLimitBytes)) }
        if let memoryBytes { o["memoryBytes"] = .number(Double(memoryBytes)) }
        return .object(o)
    }

    init?(json: JSONValue) {
        guard let id = json["id"].string, let platform = json["platform"].string else { return nil }
        self.init(id: id, platform: platform, config: json["config"].string, session: json["session"].string, cpus: json["cpus"].int,
                  cpuPercent: json["cpuPercent"].double, memoryLimitBytes: json["memoryLimitBytes"].int64, memoryBytes: json["memoryBytes"].int64)
    }
}
