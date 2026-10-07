extension Peer {
    public var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "name": .string(name), "addresses": .array(addresses.map(JSONValue.string)), "password": .string(password)]
        if !sshKey.isEmpty { o["sshKey"] = .string(sshKey) }
        return .object(o)
    }

    public init?(json: JSONValue) {
        guard let addresses = json["addresses"].array?.compactMap(\.string), !addresses.isEmpty else { return nil }
        self.init(id: json["id"].string ?? "", name: json["name"].string ?? "", addresses: addresses, password: json["password"].string ?? "",
                  sshKey: json["sshKey"].string ?? "")
    }
}
