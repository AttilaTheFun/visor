extension DirectoryReport {
    public var json: JSONValue {
        var o: [String: JSONValue] = ["client": .string(client), "clientName": .string(clientName), "servers": .array(servers.map(\.json))]
        if let clientVersion { o["clientVersion"] = .string(clientVersion) }
        if let clientPlatform { o["clientPlatform"] = .string(clientPlatform) }
        return .object(o)
    }

    public init?(json: JSONValue) {
        guard let client = json["client"].string, !client.isEmpty else { return nil }
        self.init(client: client, clientName: json["clientName"].string ?? "", clientVersion: json["clientVersion"].string,
                  clientPlatform: json["clientPlatform"].string, servers: json["servers"].array?.compactMap(DirectoryServer.init(json:)) ?? [])
    }
}
