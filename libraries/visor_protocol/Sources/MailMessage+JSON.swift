extension MailMessage {
    var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "from": from.json, "to": to.json, "text": .string(text), "sent": .number(sent),
                                      "state": .string(state.rawValue), "changed": .number(changed)]
        if let problem { o["problem"] = .string(problem) }
        return .object(o)
    }

    /// A state a later build sends, which this one hasn't heard of, reads
    /// as delivered.
    init?(json: JSONValue) {
        guard let id = json["id"].string, !id.isEmpty, let from = RelayEndpoint(json: json["from"]),
              let to = RelayEndpoint(json: json["to"]) else { return nil }
        self.init(id: id, from: from, to: to, text: json["text"].string ?? "", sent: json["sent"].double ?? 0,
                  state: json["state"].string.flatMap(State.init(rawValue:)) ?? .delivered, changed: json["changed"].double ?? 0,
                  problem: json["problem"].string)
    }
}
