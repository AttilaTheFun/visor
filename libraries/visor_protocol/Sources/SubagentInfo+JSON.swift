extension SubagentInfo {
    var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "description": .string(description), "type": .string(type), "running": .bool(running)]
        if let call { o["call"] = .string(call) }
        return .object(o)
    }

    init?(json: JSONValue) {
        guard let id = json["id"].string else { return nil }
        self.init(id: id, description: json["description"].string ?? "", type: json["type"].string ?? "",
                  running: json["running"].bool ?? false, call: json["call"].string)
    }
}
