extension RunnerUpdate {
    public var json: JSONValue {
        var object: [String: JSONValue] = ["type": .string("update"), "entry": .string(entry), "lease": .string(lease),
                                           "state": .string(state.rawValue)]
        if let dataLocation { object["dataLocation"] = .string(dataLocation) }
        if let problem { object["problem"] = .string(problem) }
        return .object(object)
    }

    public init?(json: JSONValue) {
        guard json["type"].string == "update", let entry = json["entry"].string, let lease = json["lease"].string,
              let state = json["state"].string.flatMap(State.init(rawValue:)) else { return nil }
        self.init(entry: entry, lease: lease, state: state, dataLocation: json["dataLocation"].string, problem: json["problem"].string)
    }
}
