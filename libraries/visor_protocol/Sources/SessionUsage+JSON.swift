extension SessionUsage {
    var json: JSONValue {
        var o: [String: JSONValue] = ["input": .number(Double(input)), "cached": .number(Double(cached)), "output": .number(Double(output))]
        if let cost { o["cost"] = .number(cost) }
        return .object(o)
    }

    init?(json: JSONValue) {
        guard json["input"].double != nil || json["output"].double != nil else { return nil }
        self.init(input: json["input"].int64 ?? 0, cached: json["cached"].int64 ?? 0,
                  output: json["output"].int64 ?? 0, cost: json["cost"].double)
    }
}
