extension AgentModel {
    var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "title": .string(title), "efforts": .array(efforts.map(JSONValue.string))]
        if let subtitle { o["subtitle"] = .string(subtitle) }
        if let defaultEffort { o["defaultEffort"] = .string(defaultEffort) }
        if let group { o["group"] = .string(group) }
        if !listed { o["listed"] = .bool(false) }
        return .object(o)
    }

    init?(json: JSONValue) {
        guard let id = json["id"].string, let title = json["title"].string else { return nil }
        self.init(id: id, title: title, subtitle: json["subtitle"].string,
                  efforts: json["efforts"].array?.compactMap(\.string) ?? [], defaultEffort: json["defaultEffort"].string,
                  group: json["group"].string, listed: json["listed"].bool ?? true)
    }
}
