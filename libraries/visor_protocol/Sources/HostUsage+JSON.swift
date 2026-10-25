extension HostUsage {
    var json: JSONValue {
        var o: [String: JSONValue] = ["cpus": .number(Double(cpus)), "memoryBytes": .number(Double(memoryBytes))]
        if let name { o["name"] = .string(name) }
        if let cpuPercent { o["cpuPercent"] = .number(cpuPercent) }
        if let memoryUsedBytes { o["memoryUsedBytes"] = .number(Double(memoryUsedBytes)) }
        return .object(o)
    }

    init?(json: JSONValue) {
        guard let cpus = json["cpus"].int, let memory = json["memoryBytes"].int64 else { return nil }
        self.init(name: json["name"].string, cpus: cpus, cpuPercent: json["cpuPercent"].double, memoryBytes: memory,
                  memoryUsedBytes: json["memoryUsedBytes"].int64)
    }
}
