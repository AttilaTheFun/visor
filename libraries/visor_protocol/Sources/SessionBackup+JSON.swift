extension SessionBackup {
    public var json: JSONValue {
        .object(["path": .string(path), "created": .number(created), "from": .string(from),
                 "sessions": .array(sessions.map(\.json)), "size": .number(Double(size))])
    }

    public init?(json: JSONValue) {
        guard let path = json["path"].string else { return nil }
        self.init(path: path, created: json["created"].double ?? 0, from: json["from"].string ?? "",
                  sessions: (json["sessions"].array ?? []).compactMap(SessionBackupItem.init(json:)), size: json["size"].int ?? 0)
    }
}
