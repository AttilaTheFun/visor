extension UsageLimit {
    var json: JSONValue {
        var o: [String: JSONValue] = ["name": .string(name)]
        if let used { o["used"] = .number(used) }
        if let resets { o["resets"] = .number(resets) }
        if let left { o["left"] = .number(left) }
        if let total { o["total"] = .number(total) }
        if let unit { o["unit"] = .string(unit.rawValue) }
        return .object(o)
    }

    init?(json: JSONValue) {
        guard let name = json["name"].string else { return nil }
        self.init(name: name, used: json["used"].double, resets: json["resets"].double, left: json["left"].double,
                  total: json["total"].double, unit: json["unit"].string.flatMap(Unit.init(rawValue:)))
    }
}
