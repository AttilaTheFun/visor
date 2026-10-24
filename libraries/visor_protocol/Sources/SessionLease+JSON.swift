extension SessionLease {
    var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "platform": .string(platform), "state": .string(state)]
        if let config { o["config"] = .string(config) }
        if let expires { o["expires"] = .number(expires) }
        return .object(o)
    }

    init?(json: JSONValue) {
        guard let id = json["id"].string, let platform = json["platform"].string, let state = json["state"].string else { return nil }
        self.init(id: id, platform: platform, config: json["config"].string, state: state, expires: json["expires"].double)
    }
}
