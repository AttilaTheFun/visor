extension TurnState {
    /// `{"phase": "waiting", "waits": [...]}`; `waits` only when there are
    /// some.
    public var json: JSONValue {
        var o: [String: JSONValue] = ["phase": .string(phase.rawValue)]
        if !waits.isEmpty { o["waits"] = .array(waits.map(\.json)) }
        return .object(o)
    }

    /// Nil for anything that isn't a turn's state, or a phase a later
    /// server has and this client hasn't heard of.
    public init?(json: JSONValue) {
        guard let phase = json["phase"].string.flatMap(Phase.init(rawValue:)) else { return nil }
        self.init(phase, waits: json["waits"].array?.compactMap(TurnWait.init(json:)) ?? [])
    }
}
