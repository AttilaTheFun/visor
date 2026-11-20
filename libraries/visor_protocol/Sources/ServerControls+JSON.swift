extension ServerControls.Settings {
    public var json: JSONValue {
        .object(["authentication": .string(authentication), "lan": .bool(lan), "vpn": .bool(vpn), "sshEnabled": .bool(sshEnabled),
                 "proxyEnabled": .bool(proxyEnabled), "publicAddress": .string(publicAddress), "tlsIdentityPath": .string(tlsIdentityPath),
                 "detachAgents": .bool(detachAgents), "clientsKeepMessages": .bool(clientsKeepMessages)])
    }

    public init(json: JSONValue) {
        let defaults = ServerControls.Settings()
        self.init(authentication: json["authentication"].string ?? defaults.authentication, lan: json["lan"].bool ?? defaults.lan,
                  vpn: json["vpn"].bool ?? defaults.vpn, sshEnabled: json["sshEnabled"].bool ?? defaults.sshEnabled,
                  proxyEnabled: json["proxyEnabled"].bool ?? defaults.proxyEnabled, publicAddress: json["publicAddress"].string ?? "",
                  tlsIdentityPath: json["tlsIdentityPath"].string ?? "", detachAgents: json["detachAgents"].bool ?? defaults.detachAgents,
                  clientsKeepMessages: json["clientsKeepMessages"].bool ?? defaults.clientsKeepMessages)
    }
}

extension ServerControls {
    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "type": .string("settings"), "host": .string(host), "id": .string(id), "version": .string(version), "port": .number(Double(port)),
            "password": .string(password), "listening": .bool(listening), "clientCount": .number(Double(clientCount)),
            "servesTLS": .bool(servesTLS), "sshPaths": .array(sshPaths.map { .string($0) }), "settings": settings.json,
            "apnsKeyID": .string(apnsKeyID), "apnsTeamID": .string(apnsTeamID), "apnsConfigured": .bool(apnsConfigured),
            "pushDevices": .number(Double(pushDevices)), "hasAdminToken": .bool(hasAdminToken),
        ]
        if let lastError { o["lastError"] = .string(lastError) }
        if let updateNotice { o["updateNotice"] = .string(updateNotice) }
        if let reachableAddress { o["reachableAddress"] = .string(reachableAddress) }
        if let codes { o["codes"] = codes.json }
        if let detachingSet { o["detachingSet"] = .bool(detachingSet) }
        return .object(o)
    }

    /// Nil for anything that isn't one (an error's answer).
    public init?(json: JSONValue) {
        guard json["type"].string == "settings", !json["settings"].isNull else { return nil }
        self.init()
        host = json["host"].string ?? ""
        id = json["id"].string ?? ""
        version = json["version"].string ?? ""
        port = json["port"].int ?? port
        password = json["password"].string ?? ""
        listening = json["listening"].bool ?? false
        lastError = json["lastError"].string
        updateNotice = json["updateNotice"].string
        reachableAddress = json["reachableAddress"].string
        codes = ConnectionCodes(json: json["codes"])
        clientCount = json["clientCount"].int ?? 0
        servesTLS = json["servesTLS"].bool ?? false
        sshPaths = (json["sshPaths"].array ?? []).compactMap(\.string)
        settings = Settings(json: json["settings"])
        detachingSet = json["detachingSet"].bool
        apnsKeyID = json["apnsKeyID"].string ?? ""
        apnsTeamID = json["apnsTeamID"].string ?? ""
        apnsConfigured = json["apnsConfigured"].bool ?? false
        pushDevices = json["pushDevices"].int ?? 0
        hasAdminToken = json["hasAdminToken"].bool ?? false
    }
}
