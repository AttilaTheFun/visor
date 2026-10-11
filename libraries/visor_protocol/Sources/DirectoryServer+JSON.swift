extension DirectoryServer {
    public var json: JSONValue {
        .object(["id": .string(id), "name": .string(name), "sessions": .array(sessions.map(\.json))])
    }

    public init?(json: JSONValue) {
        guard let id = json["id"].string, !id.isEmpty else { return nil }
        self.init(id: id, name: json["name"].string ?? "", sessions: json["sessions"].array?.compactMap(DirectorySession.init(json:)) ?? [])
    }
}
