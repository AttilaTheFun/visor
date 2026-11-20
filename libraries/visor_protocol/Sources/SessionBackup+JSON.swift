extension SessionBackup {
    public var json: JSONValue {
        var fields: [String: JSONValue] = ["path": .string(path), "created": .number(created), "from": .string(from),
                                           "sessions": .array(sessions.map(\.json)), "size": .number(Double(size))]
        if imported { fields["imported"] = .bool(true) }
        return .object(fields)
    }

    public init?(json: JSONValue) {
        guard let path = json["path"].string else { return nil }
        self.init(path: path, created: json["created"].double ?? 0, from: json["from"].string ?? "",
                  sessions: (json["sessions"].array ?? []).compactMap(SessionBackupItem.init(json:)), size: json["size"].int ?? 0,
                  imported: json["imported"].bool ?? false)
    }
}
