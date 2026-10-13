extension MigrationFile {
    public var json: JSONValue {
        .object(["id": .string(id), "place": .string(place), "size": .number(Double(size)), "packed": .bool(packed)])
    }

    public init?(json: JSONValue) {
        guard let id = json["id"].string, !id.isEmpty else { return nil }
        self.init(id: id, place: json["place"].string ?? "", size: json["size"].int ?? 0, packed: json["packed"].bool ?? false)
    }
}
