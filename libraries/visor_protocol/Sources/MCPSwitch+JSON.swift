extension MCPSwitch {
    var json: JSONValue { .object(["name": .string(name), "on": .bool(on)]) }

    init?(json: JSONValue) {
        guard let name = json["name"].string else { return nil }
        self.init(name: name, on: json["on"].bool ?? true)
    }
}
