extension SessionContainer {
    var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id)]
        if let image { o["image"] = .string(image) }
        return .object(o)
    }

    init?(json: JSONValue) {
        guard let id = json["id"].string else { return nil }
        self.init(id: id, image: json["image"].string)
    }
}
