extension TurnWait {
    var json: JSONValue {
        var o: [String: JSONValue] = ["kind": .string(kind.rawValue), "id": .string(id), "label": .string(label)]
        if let work { o["work"] = .string(work.rawValue) }
        return .object(o)
    }

    /// Nil for a kind a later server has and this client hasn't heard of.
    init?(json: JSONValue) {
        guard let kind = json["kind"].string.flatMap(Kind.init(rawValue:)), let id = json["id"].string else { return nil }
        self.init(kind: kind, id: id, label: json["label"].string ?? "", work: json["work"].string.flatMap(StatusItem.Kind.init(rawValue:)))
    }
}
