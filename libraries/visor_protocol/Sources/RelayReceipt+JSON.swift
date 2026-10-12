extension RelayReceipt {
    public var json: JSONValue {
        .object(["message": .string(message), "outcome": .string(outcome.rawValue), "text": .string(text)])
    }

    public init?(json: JSONValue) {
        guard let message = json["message"].string, !message.isEmpty,
              let outcome = json["outcome"].string.flatMap(Outcome.init(rawValue:)) else { return nil }
        self.init(message: message, outcome: outcome, text: json["text"].string ?? "")
    }
}
