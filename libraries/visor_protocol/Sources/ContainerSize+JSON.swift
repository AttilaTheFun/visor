extension ContainerSize {
    var json: JSONValue {
        .object(["cpus": .number(Double(cpus)), "memoryBytes": .number(Double(memoryBytes)), "diskBytes": .number(Double(diskBytes))])
    }

    init?(json: JSONValue) {
        guard let cpus = json["cpus"].int, let memory = json["memoryBytes"].int64, let disk = json["diskBytes"].int64 else { return nil }
        self.init(cpus: cpus, memoryBytes: memory, diskBytes: disk)
    }
}
