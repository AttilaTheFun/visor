extension DirectoryReport {
    public var json: JSONValue {
        .object(["client": .string(client), "clientName": .string(clientName), "servers": .array(servers.map(\.json))])
    }

    public init?(json: JSONValue) {
        guard let client = json["client"].string, !client.isEmpty else { return nil }
        self.init(client: client, clientName: json["clientName"].string ?? "",
                  servers: json["servers"].array?.compactMap(DirectoryServer.init(json:)) ?? [])
    }
}
