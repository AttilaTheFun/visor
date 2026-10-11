extension DirectorySession {
    public var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "name": .string(name)]
        if !agent.isEmpty { o["agent"] = .string(agent) }
        if busy { o["busy"] = .bool(true) }
        return .object(o)
    }

    public init?(json: JSONValue) {
        guard let id = json["id"].string, !id.isEmpty else { return nil }
        self.init(id: id, name: json["name"].string ?? "", agent: json["agent"].string ?? "", busy: json["busy"].bool ?? false)
    }
}
