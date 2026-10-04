extension AgentAccount {
    var json: JSONValue {
        var o: [String: JSONValue] = ["subscription": .bool(subscription), "limits": .array(limits.map(\.json)), "updated": .number(updated)]
        if let plan { o["plan"] = .string(plan) }
        return .object(o)
    }

    init?(json: JSONValue) {
        guard let updated = json["updated"].double else { return nil }
        self.init(plan: json["plan"].string, subscription: json["subscription"].bool ?? false,
                  limits: json["limits"].array?.compactMap(UsageLimit.init(json:)) ?? [], updated: updated)
    }
}
