extension ServerControlsChange {
    public var json: JSONValue {
        var o: [String: JSONValue] = [:]
        if let password { o["password"] = .string(password) }
        if let authentication { o["authentication"] = .string(authentication) }
        if let lan { o["lan"] = .bool(lan) }
        if let vpn { o["vpn"] = .bool(vpn) }
        if let sshEnabled { o["sshEnabled"] = .bool(sshEnabled) }
        if let proxyEnabled { o["proxyEnabled"] = .bool(proxyEnabled) }
        if let publicAddress { o["publicAddress"] = .string(publicAddress) }
        if let tlsIdentityPath { o["tlsIdentityPath"] = .string(tlsIdentityPath) }
        if let tlsPassword { o["tlsPassword"] = .string(tlsPassword) }
        if let detachAgents { o["detachAgents"] = .bool(detachAgents) }
        if let clientsKeepMessages { o["clientsKeepMessages"] = .bool(clientsKeepMessages) }
        if let containerEnabled { o["containerEnabled"] = .bool(containerEnabled) }
        if let containerCPUs { o["containerCPUs"] = containerCPUs.json }
        if let containerMemoryGiB { o["containerMemoryGiB"] = containerMemoryGiB.json }
        if let containerIdleMinutes { o["containerIdleMinutes"] = containerIdleMinutes.json }
        return .object(o)
    }

    public init(json: JSONValue) {
        self.init(password: json["password"].string, authentication: json["authentication"].string, lan: json["lan"].bool,
                  vpn: json["vpn"].bool, sshEnabled: json["sshEnabled"].bool, proxyEnabled: json["proxyEnabled"].bool,
                  publicAddress: json["publicAddress"].string, tlsIdentityPath: json["tlsIdentityPath"].string,
                  tlsPassword: json["tlsPassword"].string, detachAgents: json["detachAgents"].bool,
                  clientsKeepMessages: json["clientsKeepMessages"].bool, containerEnabled: json["containerEnabled"].bool,
                  containerCPUs: Amount(json: json, key: "containerCPUs"),
                  containerMemoryGiB: Amount(json: json, key: "containerMemoryGiB"),
                  containerIdleMinutes: Amount(json: json, key: "containerIdleMinutes"))
    }
}

extension ServerControlsChange.Amount {
    /// A number, or `null` for the default.
    public var json: JSONValue {
        switch self {
        case .to(let value): .number(Double(value))
        case .byDefault: .null
        case .unreadable(let value): value
        }
    }

    /// `key` of a change: nil when it isn't there (left as it is), the
    /// default when it's `null` or `"default"`, a whole number as set.
    init?(json: JSONValue, key: String) {
        guard let value = json.object?[key] else { return nil }
        switch value {
        case .null: self = .byDefault
        case .string(let text) where text == "default": self = .byDefault
        case .number(let n) where n == n.rounded() && abs(n) < 1e9: self = .to(Int(n))
        default: self = .unreadable(value)
        }
    }
}
