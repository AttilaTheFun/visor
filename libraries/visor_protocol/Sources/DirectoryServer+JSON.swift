extension DirectoryServer {
    public var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "name": .string(name), "sessions": .array(sessions.map(\.json))]
        if let version { o["version"] = .string(version) }
        return .object(o)
    }

    public init?(json: JSONValue) {
        guard let id = json["id"].string, !id.isEmpty else { return nil }
        self.init(id: id, name: json["name"].string ?? "", version: json["version"].string,
                  sessions: json["sessions"].array?.compactMap(DirectorySession.init(json:)) ?? [])
    }
}
