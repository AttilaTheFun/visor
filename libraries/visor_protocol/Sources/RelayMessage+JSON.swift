extension RelayMessage {
    public var json: JSONValue {
        .object(["id": .string(id), "kind": .string(kind.rawValue), "from": from.json, "to": to.json, "text": .string(text),
                 "rows": .number(Double(rows)), "created": .number(created), "expires": .number(expires)])
    }

    public init?(json: JSONValue) {
        guard let id = json["id"].string, !id.isEmpty, let kind = json["kind"].string.flatMap(Kind.init(rawValue:)),
              let from = RelayEndpoint(json: json["from"]), let to = RelayEndpoint(json: json["to"]) else { return nil }
        self.init(id: id, kind: kind, from: from, to: to, text: json["text"].string ?? "", rows: json["rows"].int ?? 10,
                  created: json["created"].double ?? 0, expires: json["expires"].double ?? 0)
    }
}
