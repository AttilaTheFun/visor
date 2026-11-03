extension SessionBackupItem {
    public var json: JSONValue {
        .object(["id": .string(id), "title": .string(title), "outcome": .string(outcome), "kept": .bool(kept)])
    }

    public init?(json: JSONValue) {
        guard let id = json["id"].string else { return nil }
        self.init(id: id, title: json["title"].string ?? "", outcome: json["outcome"].string ?? "", kept: json["kept"].bool ?? false)
    }
}
