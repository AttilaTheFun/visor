extension RelayEndpoint {
    public var json: JSONValue {
        .object(["server": .string(server), "serverName": .string(serverName), "session": .string(session), "sessionName": .string(sessionName)])
    }

    public init?(json: JSONValue) {
        guard let server = json["server"].string, !server.isEmpty, let session = json["session"].string, !session.isEmpty else { return nil }
        self.init(server: server, serverName: json["serverName"].string ?? "", session: session, sessionName: json["sessionName"].string ?? "")
    }
}
