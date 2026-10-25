extension ContainerUsage {
    var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id)]
        if let session { o["session"] = .string(session) }
        if let cpus { o["cpus"] = .number(Double(cpus)) }
        if let cpuPercent { o["cpuPercent"] = .number(cpuPercent) }
        if let memoryLimitBytes { o["memoryLimitBytes"] = .number(Double(memoryLimitBytes)) }
        if let memoryUsedBytes { o["memoryUsedBytes"] = .number(Double(memoryUsedBytes)) }
        return .object(o)
    }

    init?(json: JSONValue) {
        guard let id = json["id"].string else { return nil }
        self.init(id: id, session: json["session"].string, cpus: json["cpus"].int, cpuPercent: json["cpuPercent"].double,
                  memoryLimitBytes: json["memoryLimitBytes"].int64, memoryUsedBytes: json["memoryUsedBytes"].int64)
    }
}
