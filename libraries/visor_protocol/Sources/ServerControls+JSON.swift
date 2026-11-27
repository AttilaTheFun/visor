extension ServerControls.Settings {
    /// The container's CPUs and memory are `null` while they're the
    /// defaults.
    public var json: JSONValue {
        .object(["authentication": .string(authentication), "lan": .bool(lan), "vpn": .bool(vpn), "sshEnabled": .bool(sshEnabled),
                 "proxyEnabled": .bool(proxyEnabled), "publicAddress": .string(publicAddress), "tlsIdentityPath": .string(tlsIdentityPath),
                 "detachAgents": .bool(detachAgents), "clientsKeepMessages": .bool(clientsKeepMessages),
                 "containerEnabled": .bool(containerEnabled), "containerImageDigest": .string(containerImageDigest),
                 "containerCPUs": containerCPUs.map { JSONValue.number(Double($0)) } ?? .null,
                 "containerMemoryGiB": containerMemoryGiB.map { JSONValue.number(Double($0)) } ?? .null,
                 "containerIdleMinutes": .number(Double(containerIdleMinutes))])
    }

    public init(json: JSONValue) {
        let defaults = ServerControls.Settings()
        self.init(authentication: json["authentication"].string ?? defaults.authentication, lan: json["lan"].bool ?? defaults.lan,
                  vpn: json["vpn"].bool ?? defaults.vpn, sshEnabled: json["sshEnabled"].bool ?? defaults.sshEnabled,
                  proxyEnabled: json["proxyEnabled"].bool ?? defaults.proxyEnabled, publicAddress: json["publicAddress"].string ?? "",
                  tlsIdentityPath: json["tlsIdentityPath"].string ?? "", detachAgents: json["detachAgents"].bool ?? defaults.detachAgents,
                  clientsKeepMessages: json["clientsKeepMessages"].bool ?? defaults.clientsKeepMessages,
                  containerEnabled: json["containerEnabled"].bool ?? false, containerImageDigest: json["containerImageDigest"].string ?? "",
                  containerCPUs: json["containerCPUs"].int, containerMemoryGiB: json["containerMemoryGiB"].int,
                  containerIdleMinutes: json["containerIdleMinutes"].int ?? defaults.containerIdleMinutes)
    }
}

extension ServerControls.ContainerLimits {
    public var json: JSONValue {
        .object(["minimumCPUs": .number(Double(minimumCPUs)), "maximumCPUs": .number(Double(maximumCPUs)),
                 "defaultCPUs": .number(Double(defaultCPUs)), "minimumMemoryGiB": .number(Double(minimumMemoryGiB)),
                 "maximumMemoryGiB": .number(Double(maximumMemoryGiB)), "defaultMemoryCapGiB": .number(Double(defaultMemoryCapGiB)),
                 "minimumIdleMinutes": .number(Double(minimumIdleMinutes)), "maximumIdleMinutes": .number(Double(maximumIdleMinutes)),
                 "defaultIdleMinutes": .number(Double(defaultIdleMinutes)), "note": .string(note)])
    }

    /// Nil for what isn't one.
    public init?(json: JSONValue) {
        guard let maximumCPUs = json["maximumCPUs"].int, let maximumMemoryGiB = json["maximumMemoryGiB"].int else { return nil }
        let defaults = ServerControls.ContainerLimits(maximumCPUs: maximumCPUs, defaultCPUs: maximumCPUs, maximumMemoryGiB: maximumMemoryGiB)
        self.init(minimumCPUs: json["minimumCPUs"].int ?? defaults.minimumCPUs, maximumCPUs: maximumCPUs,
                  defaultCPUs: json["defaultCPUs"].int ?? defaults.defaultCPUs,
                  minimumMemoryGiB: json["minimumMemoryGiB"].int ?? defaults.minimumMemoryGiB, maximumMemoryGiB: maximumMemoryGiB,
                  defaultMemoryCapGiB: json["defaultMemoryCapGiB"].int ?? defaults.defaultMemoryCapGiB,
                  minimumIdleMinutes: json["minimumIdleMinutes"].int ?? defaults.minimumIdleMinutes,
                  maximumIdleMinutes: json["maximumIdleMinutes"].int ?? defaults.maximumIdleMinutes,
                  defaultIdleMinutes: json["defaultIdleMinutes"].int ?? defaults.defaultIdleMinutes, note: json["note"].string ?? "")
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
        if let containerLimits { o["containerLimits"] = containerLimits.json }
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
        containerLimits = ContainerLimits(json: json["containerLimits"])
    }
}
