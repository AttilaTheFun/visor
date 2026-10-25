extension ServerResources {
    var json: JSONValue {
        var o: [String: JSONValue] = ["sampledAt": .number(sampledAt), "containers": .array(containers.map(\.json)),
                                      "machines": .array(machines.map(\.json))]
        if let host { o["host"] = host.json }
        if let machinesHost { o["machinesHost"] = machinesHost.json }
        if let machinesNote { o["machinesNote"] = .string(machinesNote) }
        return .object(o)
    }

    init?(json: JSONValue) {
        guard let sampledAt = json["sampledAt"].double else { return nil }
        self.init(sampledAt: sampledAt, host: HostUsage(json: json["host"]),
                  containers: json["containers"].array?.compactMap(ContainerUsage.init(json:)) ?? [],
                  machines: json["machines"].array?.compactMap(MachineUsage.init(json:)) ?? [],
                  machinesHost: HostUsage(json: json["machinesHost"]), machinesNote: json["machinesNote"].string)
    }
}
