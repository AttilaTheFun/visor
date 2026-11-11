import Foundation

extension RunnerClaim {
    public var json: JSONValue {
        var object: [String: JSONValue] = ["type": .string("claim"), "entry": entry.json, "lease": .string(lease),
                                           "expires": .number(expires.timeIntervalSince1970)]
        if let agentToken { object["agentToken"] = .string(agentToken) }
        return .object(object)
    }

    public init?(json: JSONValue) {
        guard json["type"].string == "claim", let entry = QueueEntry(json: json["entry"]), let lease = json["lease"].string,
              !lease.isEmpty, let expires = json["expires"].double else { return nil }
        self.init(entry: entry, lease: lease, expires: Date(timeIntervalSince1970: expires), agentToken: json["agentToken"].string)
    }
}
