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
        return .object(o)
    }

    public init(json: JSONValue) {
        self.init(password: json["password"].string, authentication: json["authentication"].string, lan: json["lan"].bool,
                  vpn: json["vpn"].bool, sshEnabled: json["sshEnabled"].bool, proxyEnabled: json["proxyEnabled"].bool,
                  publicAddress: json["publicAddress"].string, tlsIdentityPath: json["tlsIdentityPath"].string,
                  tlsPassword: json["tlsPassword"].string, detachAgents: json["detachAgents"].bool,
                  clientsKeepMessages: json["clientsKeepMessages"].bool)
    }
}
