extension SessionContainer {
    var json: JSONValue {
        var o: [String: JSONValue] = ["server": .string(server), "id": .string(id)]
        if let repository { o["repository"] = .string(repository) }
        if let image { o["image"] = .string(image) }
        return .object(o)
    }

    init?(json: JSONValue) {
        guard let server = json["server"].string, let id = json["id"].string else { return nil }
        self.init(server: server, id: id, repository: json["repository"].string, image: json["image"].string)
    }
}
