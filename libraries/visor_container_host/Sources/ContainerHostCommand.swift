import Foundation

/// visor-container-host (docs/container-host.md): Visor's container host,
/// over Apple's `container`, with no leasing and no limits — every
/// container asked for is made. Each operation is a run of the tool; `exec`
/// becomes `container exec` (applications/visor_container_host's main).
public enum ContainerHostCommand {
    /// The contract's version this host speaks.
    public static let api = 1
    public static let name = "visor-container-host"
    /// A public name a container's network must resolve and reach.
    static let probeName = "github.com"

    /// What an operation answers: its exit status, and the JSON object it
    /// writes on standard output.
    public struct Answer {
        public var status: Int32
        public var json: [String: Any]

        public init(status: Int32, json: [String: Any]) {
            self.status = status
            self.json = json
        }

        public var text: String {
            let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }
    }

    static func failure(_ message: String, code: String? = nil) -> Answer {
        var json: [String: Any] = ["error": message]
        if let code { json["code"] = code }
        return Answer(status: 1, json: json)
    }

    /// The answer to every operation but `exec`.
    public static func answer(_ arguments: [String], input: Data, container: AppleContainer, version: String) -> Answer {
        let rest = Array(arguments.dropFirst())
        if let first = arguments.first, serverCommands.contains(first) { return serverAnswer(arguments, input: input, container: container) }
        switch arguments.first {
        case "health": return health(container, version: version)
        case "create": return create(input, container: container)
        case "put": return put(rest, input: input, container: container)
        case "rm": return remove(rest, container: container)
        case "ls": return list(container)
        case "network": return network(rest, container: container)
        default: return failure("\(name) health | serve | status | credentials | stop | upgrade | remove (version 2), "
                                + "create | exec | put | rm | ls | network (version 1)", code: "unsupported")
        }
    }

    static func health(_ container: AppleContainer, version: String) -> Answer {
        let base: [String: Any] = ["name": name, "version": version, "api": api]
        guard FileManager.default.isExecutableFile(atPath: container.tool) else {
            return Answer(status: 0, json: base.merging(["ok": false, "error": "Apple's container is not installed (github.com/apple/container)"]) { $1 })
        }
        guard let status = container.run(["system", "status"]), status.status == 0 else {
            return Answer(status: 0, json: base.merging(["ok": false, "error": "Apple's container is not started (container system start)"]) { $1 })
        }
        // No limits of its own: the most a container can have is this Mac.
        let limits: [String: Any] = ["cpus": ProcessInfo.processInfo.activeProcessorCount,
                                     "memoryBytes": ProcessInfo.processInfo.physicalMemory]
        return Answer(status: 0, json: base.merging(["ok": true, "limits": limits]) { $1 })
    }

    /// `container run`'s arguments for a request: its disks, this
    /// computer's folders, its labels, size and variables, Rosetta where
    /// asked and here, kept running.
    static func runArguments(_ request: HostRequest, rosetta: Bool) -> [String] {
        let labels = request.labels.merging(["visor.host": name, specLabel: spec(of: request)]) { $1 }
        var arguments = ["run", "--detach", "--name", request.name]
        for volume in request.volumes { arguments += ["--volume", "\(volume.name):\(volume.destination)"] }
        for mount in request.mounts {
            arguments += ["--mount", "type=bind,source=\(mount.source),target=\(mount.destination)" + (mount.readOnly == true ? ",readonly" : "")]
        }
        for (key, value) in labels.sorted(by: { $0.key < $1.key }) { arguments += ["--label", "\(key)=\(value)"] }
        if let cpus = request.cpus { arguments += ["--cpus", String(cpus)] }
        if let memory = request.memoryBytes { arguments += ["--memory", "\(max(memory / 1_048_576, 512))M"] }
        for (key, value) in request.environment.sorted(by: { $0.key < $1.key }) { arguments += ["--env", "\(key)=\(value)"] }
        if request.rosetta && rosetta { arguments += ["--rosetta"] }
        return arguments + [request.image, "sleep", "infinity"]
    }

    static func create(_ input: Data, container: AppleContainer, rosetta: Bool = AppleContainer.hasRosetta,
                       tries: Int = 15, pause: Double = 1) -> Answer {
        guard let request = try? JSONDecoder().decode(HostRequest.self, from: input) else { return failure("create is given the container as JSON") }
        guard !request.name.isEmpty, request.name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) else {
            return failure("\(request.name) can't name a container")
        }
        // Asked again for one it made: that one, started if it had stopped.
        if let had = inspected(request.name, container: container) {
            guard had.labels[specLabel] == spec(of: request) else {
                return failure("There is already a container \(request.name), made otherwise", code: "exists")
            }
            if had.status != "running", container.run(["start", request.name])?.status != 0 {
                return failure("\(request.name) is there but doesn't start")
            }
        } else {
            for volume in request.volumes {
                if let problem = ensure(volume, container: container) { return failure(problem) }
            }
            guard let made = container.run(runArguments(request, rosetta: rosetta)) else { return failure("Apple's container couldn't be started") }
            guard made.status == 0 else {
                let said = made.said
                let missing = said.localizedCaseInsensitiveContains("not found") || said.localizedCaseInsensitiveContains("pull")
                return failure("Could not make \(request.name) from \(request.image): \(said)", code: missing ? "noImage" : nil)
            }
        }
        // Handed over only once it resolves names: one that can't is no use
        // to an agent.
        for attempt in 0..<tries {
            if resolves(request.name, container: container) {
                var json: [String: Any] = ["id": request.name, "name": request.name, "image": request.image, "api": api]
                if let cpus = request.cpus { json["cpus"] = cpus }
                if let memory = request.memoryBytes { json["memoryBytes"] = memory }
                return Answer(status: 0, json: json)
            }
            if attempt < tries - 1 { Thread.sleep(forTimeInterval: pause) }
        }
        _ = container.run(["delete", "--force", request.name])
        return failure("\(request.name) was made but resolves no names: its network doesn't work", code: "network")
    }

    /// A volume there at the size asked: one at another size goes first (a
    /// volume isn't made larger or smaller). Nil, or what went wrong.
    static func ensure(_ volume: HostRequest.Volume, container: AppleContainer) -> String? {
        // In MB, as it is made.
        let megabytes = UInt64(max(volume.sizeBytes, 0)) / 1_048_576
        let size = volumeSize(volume.name, container: container).map { $0 / 1_048_576 }
        if let size, size != megabytes { _ = container.run(["volume", "delete", volume.name]) }
        guard size != megabytes else { return nil }
        guard let made = container.run(["volume", "create", "-s", "\(megabytes)M", volume.name]), made.status == 0 else {
            return "Could not make the volume \(volume.name)"
        }
        return nil
    }

    static func volumeSize(_ name: String, container: AppleContainer) -> UInt64? {
        guard let read = container.run(["volume", "inspect", name]), read.status == 0,
              let volumes = (try? JSONSerialization.jsonObject(with: Data(read.output.utf8))) as? [[String: Any]],
              let size = ((volumes.first?["configuration"] as? [String: Any])?["sizeInBytes"] as? NSNumber)?.uint64Value else { return nil }
        return size
    }

    static func resolves(_ id: String, container: AppleContainer) -> Bool {
        container.run(["exec", id, "sh", "-c", "getent hosts \(probeName) > /dev/null"])?.status == 0
    }

    static func put(_ arguments: [String], input: Data, container: AppleContainer) -> Answer {
        guard arguments.count >= 2 else { return failure("put <id> <path> [--mode=600] < bytes") }
        let mode = arguments.dropFirst(2).first { $0.hasPrefix("--mode=") }.map { String($0.dropFirst(7)) } ?? "600"
        let script = "mkdir -p \"$(dirname \"$1\")\" && cat > \"$1\" && chmod \"$2\" \"$1\""
        guard let wrote = container.run(["exec", "--interactive", arguments[0], "sh", "-c", script, "sh", arguments[1], mode], input: input),
              wrote.status == 0 else {
            return failure("Could not write \(arguments[1]) in \(arguments[0])", code: "notFound")
        }
        return Answer(status: 0, json: ["path": arguments[1], "size": input.count])
    }

    static func remove(_ arguments: [String], container: AppleContainer) -> Answer {
        guard let id = arguments.first else { return failure("rm <id> [--volumes]") }
        // One already gone is no error.
        _ = container.run(["delete", "--force", id])
        if arguments.contains("--volumes"), let listed = container.run(["volume", "list", "--format", "json"]), listed.status == 0,
           let volumes = (try? JSONSerialization.jsonObject(with: Data(listed.output.utf8))) as? [[String: Any]] {
            for volume in volumes {
                guard let name = (volume["configuration"] as? [String: Any])?["name"] as? String ?? volume["name"] as? String,
                      name.hasPrefix(id + "-") else { continue }
                _ = container.run(["volume", "delete", name])
            }
        }
        return Answer(status: 0, json: ["removed": id])
    }

    static func list(_ container: AppleContainer) -> Answer {
        guard let listed = container.run(["list", "--all", "--format", "json"]), listed.status == 0,
              let all = (try? JSONSerialization.jsonObject(with: Data(listed.output.utf8))) as? [[String: Any]] else {
            return failure("Apple's container lists nothing")
        }
        let containers: [[String: Any]] = all.compactMap { item in
            let configuration = item["configuration"] as? [String: Any] ?? [:]
            guard let id = configuration["id"] as? String, let labels = configuration["labels"] as? [String: String],
                  labels["visor.session"] != nil else { return nil }
            let image = (configuration["image"] as? [String: Any])?["reference"] as? String ?? ""
            return ["id": id, "name": id, "image": image, "state": item["status"] as? String ?? "", "labels": labels]
        }
        return Answer(status: 0, json: ["containers": containers])
    }

    static func network(_ arguments: [String], container: AppleContainer) -> Answer {
        guard let id = arguments.first else { return failure("network <id>") }
        let script = "getent hosts \(probeName) > /dev/null && echo dns; curl -s -o /dev/null --max-time 8 https://\(probeName) && echo reach"
        guard let checked = container.run(["exec", id, "sh", "-c", script]) else { return failure("Apple's container couldn't be started") }
        let dns = checked.output.contains("dns"), reach = checked.output.contains("reach")
        let detail = dns && reach ? "resolves and reaches \(probeName)" : !dns ? "resolves no names (\(probeName))" : "resolves, but reaches nothing (\(probeName))"
        return Answer(status: 0, json: ["ok": dns && reach, "dns": dns, "reach": reach, "detail": detail])
    }

    /// The label a container carries its request's digest in: `create`
    /// asked again for the same one answers it rather than make another.
    static let specLabel = "visor.host.spec"

    /// A request's digest: FNV-1a over its JSON, keys sorted. Told apart
    /// from another request, not kept secret.
    static func spec(of request: HostRequest) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(request)) ?? Data()
        let hash = data.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
        return String(hash, radix: 16)
    }

    /// A container's state and labels; nil when there is no such container.
    static func inspected(_ id: String, container: AppleContainer) -> (status: String, labels: [String: String])? {
        guard let read = container.run(["inspect", id]), read.status == 0,
              let items = (try? JSONSerialization.jsonObject(with: Data(read.output.utf8))) as? [[String: Any]],
              let item = items.first else { return nil }
        let labels = (item["configuration"] as? [String: Any])?["labels"] as? [String: String] ?? [:]
        return (item["status"] as? String ?? "", labels)
    }

    /// The container running, started again if it has stopped (this Mac
    /// restarted, say): `exec` runs in it next. False when there is no such
    /// container.
    public static func started(_ id: String, container: AppleContainer) -> Bool {
        guard let had = inspected(id, container: container) else { return false }
        if had.status == "running" { return true }
        return container.run(["start", id])?.status == 0
    }

    /// `container exec`'s arguments for `exec <id> [--interactive] [--tty]
    /// [--workdir=DIR] [--env-file=FILE] -- program…`: standard input
    /// always attached (read to its end, or kept open); with `--tty`, a
    /// terminal, sized as the one this runs on and resized with it. Nil for
    /// arguments it can't read.
    public static func execArguments(_ arguments: [String]) -> (id: String, arguments: [String])? {
        guard let id = arguments.first, let split = arguments.firstIndex(of: "--"), split > 0, split + 1 < arguments.count else { return nil }
        var options = ["exec", "--interactive"]
        for option in arguments[1..<split] {
            if option == "--tty" { options += ["--tty"] }
            if option.hasPrefix("--workdir=") { options += ["--workdir", String(option.dropFirst("--workdir=".count))] }
            if option.hasPrefix("--env-file=") { options += ["--env-file", String(option.dropFirst("--env-file=".count))] }
        }
        return (id, options + [id] + arguments[(split + 1)...])
    }
}
